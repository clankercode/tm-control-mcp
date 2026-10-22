//! Shared core for the `mcp-cli` binary.

use std::{
    collections::{BTreeMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use futures::future::BoxFuture;
use jsonschema::{Draft, Validator};
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler,
    model::{
        CacheScope, CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock,
        Implementation, ListResourcesResult, ListToolsResult, ReadResourceRequestParams,
        ReadResourceResponse, ReadResourceResult, Resource, ResourceContents, ServerCapabilities,
        ServerConfig, SubscriptionFilter, Tool,
    },
    service::{RequestContext, SubscriptionContext},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{RwLock as AsyncRwLock, broadcast, mpsc},
    time::timeout,
};
use tokio_util::sync::CancellationToken;

pub const DEFAULT_NATIVE_HOST: &str = "127.0.0.1";
pub const DEFAULT_NATIVE_PORT: u16 = 30006;
pub const DEFAULT_HTTP_ADDR: &str = "127.0.0.1:30007";
pub const MAX_NATIVE_FRAME: usize = 16 * 1024 * 1024;
pub const NATIVE_TIMEOUT: Duration = Duration::from_secs(10);
pub const MAX_EVENT_COPY: usize = 2048;
pub const MAX_EVENTS: usize = 256;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NativeResponse {
    pub ok: bool,
    #[serde(default)]
    pub id: Value,
    #[serde(default)]
    pub route: String,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub data: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NativeTool {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(rename = "input_schema", default)]
    pub input_schema: Value,
    #[serde(default)]
    pub pack: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CatalogIdentity {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u64,
    pub instance: String,
    pub revision: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NativeCatalog {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u64,
    pub instance: String,
    pub revision: String,
    pub tools: Vec<NativeTool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Event {
    pub invocation_id: String,
    pub connection_id: String,
    pub request_id: String,
    pub method: String,
    pub tool: Option<String>,
    pub started_ms: u128,
    pub ended_ms: u128,
    pub status: String,
    pub argument_bytes: usize,
    pub result_bytes: usize,
    pub arguments: String,
    pub result: String,
}

#[derive(Debug, Clone)]
pub enum CoreEvent {
    Invocation(Event),
    CatalogChanged(String),
}

#[derive(Debug)]
pub struct MonitorStore {
    events: Mutex<VecDeque<Event>>,
    sequence: std::sync::atomic::AtomicU64,
    events_tx: broadcast::Sender<CoreEvent>,
    jsonl_tx: Option<mpsc::Sender<Event>>,
}

impl MonitorStore {
    pub fn new(jsonl_path: Option<PathBuf>) -> Arc<Self> {
        let (events_tx, _) = broadcast::channel(128);
        let jsonl_tx = jsonl_path.map(|path| {
            let (tx, mut rx) = mpsc::channel::<Event>(128);
            tokio::spawn(async move {
                while let Some(event) = rx.recv().await {
                    if let Err(error) = append_jsonl(&path, &event).await {
                        tracing::warn!(%error, "metadata JSONL write failed");
                    }
                }
            });
            tx
        });
        Arc::new(Self {
            events: Mutex::new(VecDeque::with_capacity(MAX_EVENTS)),
            sequence: std::sync::atomic::AtomicU64::new(1),
            events_tx,
            jsonl_tx,
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<CoreEvent> {
        self.events_tx.subscribe()
    }

    pub fn snapshot(&self) -> Vec<Event> {
        self.events
            .lock()
            .expect("monitor mutex poisoned")
            .iter()
            .cloned()
            .collect()
    }

    pub fn next_id(&self) -> String {
        format!(
            "inv-{}",
            self.sequence
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        )
    }

    pub fn record(&self, event: Event) {
        {
            let mut events = self.events.lock().expect("monitor mutex poisoned");
            if events.len() == MAX_EVENTS {
                events.pop_front();
            }
            events.push_back(event.clone());
        }
        if let Some(tx) = &self.jsonl_tx {
            let _ = tx.try_send(event.clone());
        }
        let _ = self.events_tx.send(CoreEvent::Invocation(event));
    }

    pub fn catalog_changed(&self, revision: String) {
        let _ = self.events_tx.send(CoreEvent::CatalogChanged(revision));
    }
}

async fn append_jsonl(path: &PathBuf, event: &Event) -> Result<()> {
    let line = serde_json::to_vec(event)?;
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await
        .with_context(|| format!("open metadata JSONL {}", path.display()))?;
    file.write_all(&line).await?;
    file.write_all(b"\n").await?;
    Ok(())
}

pub trait NativeBackend: Send + Sync {
    fn status(&self) -> BoxFuture<'static, Result<NativeResponse>>;
    fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>>;
    fn call(&self, tool: String, input: Value) -> BoxFuture<'static, Result<NativeResponse>>;
}

#[derive(Clone)]
pub struct NativeTcpClient {
    host: String,
    port: u16,
}

impl NativeTcpClient {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
        }
    }

    async fn request(&self, request: Value) -> Result<NativeResponse> {
        let mut stream = timeout(NATIVE_TIMEOUT, TcpStream::connect((&*self.host, self.port)))
            .await
            .context("native connect timed out")??;
        let bytes = serde_json::to_vec(&request)?;
        if bytes.len() > MAX_NATIVE_FRAME - 1 {
            return Err(anyhow!(
                "native request exceeds {} byte bound",
                MAX_NATIVE_FRAME
            ));
        }
        stream.write_all(&bytes).await?;
        stream.write_all(b"\n").await?;
        stream.flush().await?;
        let frame = timeout(NATIVE_TIMEOUT, read_frame(&mut stream, MAX_NATIVE_FRAME))
            .await
            .context("native response timed out")??;
        serde_json::from_slice(&frame).context("decode native response")
    }
}

impl NativeBackend for NativeTcpClient {
    fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move { client.request(json!({"route":"status"})).await })
    }

    fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move { client.request(json!({"route":"catalog"})).await })
    }

    fn call(&self, tool: String, input: Value) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move {
            client
                .request(json!({"route":"call","tool":tool,"input":input}))
                .await
        })
    }
}

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R, max: usize) -> Result<Vec<u8>> {
    let mut frame = Vec::with_capacity(1024);
    let mut chunk = [0_u8; 1024];
    loop {
        let read = reader.read(&mut chunk).await?;
        if read == 0 {
            if frame.is_empty() {
                return Err(anyhow!("native peer closed before a frame"));
            }
            return Ok(frame);
        }
        let end = chunk[..read].iter().position(|byte| *byte == b'\n');
        let take = end.unwrap_or(read);
        if frame.len().saturating_add(take) > max {
            return Err(anyhow!("frame exceeds {} byte bound", max));
        }
        frame.extend_from_slice(&chunk[..take]);
        if end.is_some() {
            while frame.last().is_some_and(|byte| byte.is_ascii_whitespace()) {
                frame.pop();
            }
            return Ok(frame);
        }
    }
}

#[derive(Debug, Clone)]
pub struct CatalogSnapshot {
    pub identity: CatalogIdentity,
    pub tools: BTreeMap<String, NativeTool>,
}

impl CatalogSnapshot {
    fn from_response(response: NativeResponse) -> Result<Self> {
        if !response.ok {
            return Err(anyhow!("native catalog failed: {}", response.error));
        }
        let catalog: NativeCatalog = serde_json::from_value(response.data)?;
        let tools = catalog
            .tools
            .into_iter()
            .map(|tool| (tool.name.clone(), tool))
            .collect();
        Ok(Self {
            identity: CatalogIdentity {
                schema_version: catalog.schema_version,
                instance: catalog.instance,
                revision: catalog.revision,
            },
            tools,
        })
    }
}

pub struct Core {
    backend: Arc<dyn NativeBackend>,
    catalog: AsyncRwLock<Option<CatalogSnapshot>>,
    monitor: Arc<MonitorStore>,
    guide_text: BTreeMap<String, String>,
}

impl Core {
    pub fn new(backend: Arc<dyn NativeBackend>, monitor: Arc<MonitorStore>) -> Arc<Self> {
        Arc::new(Self {
            backend,
            catalog: AsyncRwLock::new(None),
            monitor,
            guide_text: guide_text(),
        })
    }

    pub fn monitor(&self) -> Arc<MonitorStore> {
        self.monitor.clone()
    }

    pub async fn refresh_catalog(&self) -> Result<CatalogSnapshot> {
        let snapshot = CatalogSnapshot::from_response(self.backend.catalog().await?)?;
        let changed = self
            .catalog
            .read()
            .await
            .as_ref()
            .map(|old| old.identity != snapshot.identity)
            .unwrap_or(true);
        *self.catalog.write().await = Some(snapshot.clone());
        if changed {
            self.monitor
                .catalog_changed(snapshot.identity.revision.clone());
        }
        Ok(snapshot)
    }

    pub async fn catalog(&self) -> Result<CatalogSnapshot> {
        if let Some(catalog) = self.catalog.read().await.clone() {
            return Ok(catalog);
        }
        self.refresh_catalog().await
    }

    pub fn start_catalog_poller(
        self: &Arc<Self>,
        interval: Duration,
        cancellation: CancellationToken,
    ) {
        let core = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(interval);
            loop {
                tokio::select! {
                    _ = cancellation.cancelled() => break,
                    _ = tick.tick() => {
                        if let Err(error) = core.refresh_catalog().await { tracing::debug!(%error, "catalog poll failed"); }
                    }
                }
            }
        });
    }

    pub async fn status(&self) -> Result<NativeResponse> {
        self.backend.status().await
    }

    pub async fn call(
        &self,
        tool: &str,
        input: Value,
        connection_id: &str,
        request_id: &str,
    ) -> Result<NativeResponse> {
        let catalog = self.catalog().await?;
        let descriptor = catalog
            .tools
            .get(tool)
            .ok_or_else(|| anyhow!("unknown tool: {tool}"))?;
        validate_input(&descriptor.input_schema, &input)?;
        let started = now_ms();
        let result = self.backend.call(tool.to_owned(), input.clone()).await;
        let ended = now_ms();
        let (status, result_value, error) = match &result {
            Ok(response) if response.ok => ("ok", response.data.clone(), None),
            Ok(response) => (
                "tool_error",
                response.data.clone(),
                Some(response.error.clone()),
            ),
            Err(error) => ("transport_error", Value::Null, Some(error.to_string())),
        };
        let safe_input = sanitize_value(&input);
        let safe_result = sanitize_value(&json!({"data": result_value, "error": error}));
        self.monitor.record(Event {
            invocation_id: self.monitor.next_id(),
            connection_id: bounded(connection_id),
            request_id: bounded(request_id),
            method: "tools/call".to_owned(),
            tool: Some(bounded(tool)),
            started_ms: started,
            ended_ms: ended,
            status: status.to_owned(),
            argument_bytes: serde_json::to_vec(&input).map(|v| v.len()).unwrap_or(0),
            result_bytes: serde_json::to_vec(&result_value)
                .map(|v| v.len())
                .unwrap_or(0),
            arguments: bounded_json(&safe_input),
            result: bounded_json(&safe_result),
        });
        result
    }

    pub fn guides(&self) -> &BTreeMap<String, String> {
        &self.guide_text
    }
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
fn bounded(value: &str) -> String {
    value.chars().take(MAX_EVENT_COPY).collect()
}
fn bounded_json(value: &Value) -> String {
    bounded(&serde_json::to_string(value).unwrap_or_else(|_| "<unserializable>".into()))
}

fn sanitize_value(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, value)| {
                    let lower = key.to_ascii_lowercase();
                    let redacted = [
                        "token",
                        "password",
                        "secret",
                        "authorization",
                        "accesskey",
                        "privatekey",
                    ]
                    .iter()
                    .any(|needle| lower.contains(needle));
                    (
                        bounded(key),
                        if redacted {
                            Value::String("[redacted]".into())
                        } else {
                            sanitize_value(value)
                        },
                    )
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(sanitize_value).collect()),
        Value::String(string) => Value::String(bounded(string)),
        other => other.clone(),
    }
}

fn normalize_screenshot_output(value: Value) -> Value {
    match value {
        Value::Object(mut map) => {
            if let Some(screenshot) = map.remove("detectedScreenshot") {
                let path = screenshot
                    .get("linuxPath")
                    .or_else(|| screenshot.get("path"))
                    .and_then(Value::as_str)
                    .map(bounded)
                    .unwrap_or_default();
                map.insert(
                    "screenshot".into(),
                    json!({
                        "kind": "path",
                        "path": path,
                        "verified": false,
                        "note": "The adapter exposes the native path and does not read image bytes."
                    }),
                );
            }
            Value::Object(
                map.into_iter()
                    .map(|(key, value)| (key, normalize_screenshot_output(value)))
                    .collect(),
            )
        }
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(normalize_screenshot_output)
                .collect(),
        ),
        other => other,
    }
}

struct DenyExternalReferences;

impl jsonschema::Retrieve for DenyExternalReferences {
    fn retrieve(
        &self,
        _uri: &jsonschema::Uri<String>,
    ) -> std::result::Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        Err("external schema references are disabled".into())
    }
}

pub fn validate_input(schema: &Value, input: &Value) -> Result<()> {
    if !schema.is_object() {
        return Err(anyhow!("tool schema must be a JSON object"));
    }
    let validator: Validator = jsonschema::options()
        .with_draft(Draft::Draft202012)
        .with_retriever(DenyExternalReferences)
        .build(schema)
        .context("compile tool input schema")?;
    if let Err(error) = validator.validate(input) {
        return Err(anyhow!("invalid tool input: {error}"));
    }
    Ok(())
}

#[derive(Clone)]
pub struct McpAdapter {
    pub core: Arc<Core>,
}

impl McpAdapter {
    pub fn new(core: Arc<Core>) -> Self {
        Self { core }
    }

    fn tools(&self, catalog: CatalogSnapshot) -> Vec<Tool> {
        catalog
            .tools
            .into_values()
            .map(|tool| {
                let schema = tool.input_schema.as_object().cloned().unwrap_or_default();
                Tool::new_with_raw(tool.name, Some(tool.description.into()), Arc::new(schema))
            })
            .collect()
    }

    fn resources(&self) -> Vec<Resource> {
        self.core
            .guides()
            .keys()
            .map(|key| {
                Resource::new(format!("tm-control://guide/{key}"), key.clone())
                    .with_mime_type("text/markdown")
                    .with_description("Built-in tm-control-mcp guide")
            })
            .collect()
    }
}

impl ServerHandler for McpAdapter {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources().enable_tool_list_changed().enable_resources_list_changed().build())
            .with_server_info(Implementation::new("tm-control-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions("Tools are forwarded to the local Openplanet tm-control-mcp bridge. Native failures are returned as tool-level errors.")
    }

    fn supported_protocol_versions(
        &self,
    ) -> std::borrow::Cow<'static, [rmcp::model::ProtocolVersion]> {
        std::borrow::Cow::Borrowed(&[
            rmcp::model::ProtocolVersion::V_2026_07_28,
            rmcp::model::ProtocolVersion::V_2025_11_25,
            rmcp::model::ProtocolVersion::V_2025_06_18,
        ])
    }

    async fn list_tools(
        &self,
        _request: Option<rmcp::model::PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        let catalog = self.core.catalog().await.map_err(internal_error)?;
        Ok(ListToolsResult::with_all_items(self.tools(catalog))
            .with_ttl_ms(0)
            .with_cache_scope(CacheScope::Private))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let input = Value::Object(request.arguments.unwrap_or_default());
        let tool = request.name.to_string();
        let result = self
            .core
            .call(&tool, input, "mcp", &request_id(&context.id))
            .await;
        match result {
            Ok(response) if response.ok => Ok(native_result(response.data, false).into()),
            Ok(response) => Ok(native_result(
                json!({"success":false,"error":response.error,"data":response.data}),
                true,
            )
            .into()),
            Err(error) if error.to_string().starts_with("unknown tool:") => {
                Err(McpError::invalid_params(error.to_string(), None))
            }
            Err(error)
                if error.to_string().starts_with("invalid tool input:")
                    || error.to_string().contains("schema") =>
            {
                Err(McpError::invalid_params(error.to_string(), None))
            }
            Err(error) => Ok(CallToolResult::structured_error(
                json!({"code":"native_transport","message":error.to_string()}),
            )
            .into()),
        }
    }

    async fn list_resources(
        &self,
        _request: Option<rmcp::model::PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        Ok(ListResourcesResult::with_all_items(self.resources())
            .with_ttl_ms(0)
            .with_cache_scope(CacheScope::Private))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, McpError> {
        let prefix = "tm-control://guide/";
        let key = request
            .uri
            .strip_prefix(prefix)
            .ok_or_else(|| McpError::resource_not_found(request.uri.clone(), None))?;
        let text = self
            .core
            .guides()
            .get(key)
            .ok_or_else(|| McpError::resource_not_found(request.uri.clone(), None))?;
        Ok(
            ReadResourceResult::new(vec![ResourceContents::text(text.clone(), request.uri)])
                .with_ttl_ms(0)
                .with_cache_scope(CacheScope::Private)
                .into(),
        )
    }

    fn accepted_subscription_filter(
        &self,
        requested: &SubscriptionFilter,
    ) -> Option<SubscriptionFilter> {
        Some(
            SubscriptionFilter::builder()
                .tools_list_changed()
                .resources_list_changed()
                .build()
                .intersection(requested),
        )
    }

    async fn listen(&self, context: SubscriptionContext) -> Result<(), McpError> {
        let mut events = self.core.monitor.subscribe();
        loop {
            tokio::select! {
                _ = context.cancelled() => return Ok(()),
                event = events.recv() => match event {
                    Ok(CoreEvent::CatalogChanged(_)) => {
                        let _ = context.sink().notify_tool_list_changed().await;
                    }
                    Ok(CoreEvent::Invocation(_)) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
        }
    }
}

fn request_id(id: &rmcp::model::RequestId) -> String {
    serde_json::to_string(id).unwrap_or_else(|_| "unknown".into())
}
fn internal_error(error: anyhow::Error) -> McpError {
    McpError::internal_error(error.to_string(), None)
}

fn native_result(data: Value, error: bool) -> CallToolResult {
    let output = data
        .get("result")
        .and_then(|result| result.get("output"))
        .cloned()
        .unwrap_or(data);
    let output = normalize_screenshot_output(output);
    let mut result = if error {
        CallToolResult::structured_error(output)
    } else {
        CallToolResult::structured(output)
    };
    if result.content.is_empty() {
        result.content.push(ContentBlock::text("{}"));
    }
    result
}

fn guide_text() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("index".into(), "tm-control-mcp guides: readiness, placement, and screenshot handling.\n".into()),
        ("readiness".into(), "Call GetReadiness before mutations. Use WaitUntil for editor/menu transitions and shadowsClear before plugin reloads during a lightmap bake.\n".into()),
        ("placement".into(), "Prefer E++ free placement and named macroblocks. SetAgentTag before smoke placement and RemoveByTag for cleanup.\n".into()),
        ("screenshots".into(), "The adapter does not read native screenshot paths as image bytes. Native screenshot output is returned as bounded structured path metadata, so clients can decide how to open it.\n".into()),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeBackend;
    impl NativeBackend for FakeBackend {
        fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async {
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "status".into(),
                    error: String::new(),
                    data: json!({"alive":true}),
                })
            })
        }
        fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async {
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "catalog".into(),
                    error: String::new(),
                    data: json!({"schemaVersion":1,"instance":"fake","revision":"1","tools":[{"name":"Echo","description":"echo","input_schema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false},"pack":""}]}),
                })
            })
        }
        fn call(&self, _tool: String, input: Value) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async move {
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "call".into(),
                    error: String::new(),
                    data: json!({"tool":"Echo","result":{"success":true,"output":input}}),
                })
            })
        }
    }

    #[tokio::test]
    async fn fake_backend_validates_nested_schema_and_maps_output() {
        let monitor = MonitorStore::new(None);
        let core = Core::new(Arc::new(FakeBackend), monitor);
        let result = core
            .call("Echo", json!({"message":"hello"}), "test", "1")
            .await
            .unwrap();
        assert!(result.ok);
        assert!(core.call("Echo", json!({}), "test", "2").await.is_err());
    }

    #[test]
    fn rejects_network_refs_and_accepts_full_draft_2020_12_validation() {
        assert!(validate_input(&json!({"type":"object","properties":{"x":{"type":"array","items":{"type":"integer"}}},"required":["x"]}), &json!({"x":[1,2]})).is_ok());
        assert!(
            validate_input(
                &json!({"$ref":"https://example.invalid/schema"}),
                &json!({})
            )
            .is_err()
        );
        assert!(validate_input(&json!({"type":"object","required":["x"]}), &json!({})).is_err());
    }

    #[tokio::test]
    async fn frame_reader_handles_split_utf8_and_rejects_bounds() {
        let (mut writer, mut reader) = tokio::io::duplex(64);
        let task = tokio::spawn(async move {
            writer
                .write_all("{\"x\":\"☃\"}\n".as_bytes())
                .await
                .unwrap();
        });
        let frame = read_frame(&mut reader, 64).await.unwrap();
        task.await.unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&frame).unwrap()["x"], "☃");
        let (mut writer, mut reader) = tokio::io::duplex(64);
        let task = tokio::spawn(async move {
            writer.write_all(b"123456789\n").await.unwrap();
        });
        assert!(read_frame(&mut reader, 4).await.is_err());
        task.await.unwrap();
    }

    #[test]
    fn monitor_redacts_secrets_and_screenshot_paths_are_bounded_metadata() {
        let monitor = MonitorStore::new(None);
        monitor.record(Event {
            invocation_id: "inv-1".into(),
            connection_id: "mcp".into(),
            request_id: "1".into(),
            method: "tools/call".into(),
            tool: Some("TakeScreenshot".into()),
            started_ms: 1,
            ended_ms: 2,
            status: "ok".into(),
            argument_bytes: 20,
            result_bytes: 20,
            arguments: bounded_json(&sanitize_value(&json!({"accessToken":"secret"}))),
            result: bounded_json(&sanitize_value(&json!({"path":"/tmp/private.png"}))),
        });
        assert!(!monitor.snapshot()[0].arguments.contains("secret"));
        let output = native_result(
            json!({"result":{"output":{"detectedScreenshot":{"linuxPath":"/tmp/a.png"}}}}),
            false,
        );
        assert_eq!(
            output.structured_content.unwrap()["screenshot"]["verified"],
            false
        );
    }
}

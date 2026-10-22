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
        ReadResourceResponse, ReadResourceResult, Resource, ResourceContents, ResourcesCapability,
        ServerCapabilities, ServerConfig, SubscribeRequestParams, SubscriptionFilter, Tool,
        UnsubscribeRequestParams,
    },
    service::{RequestContext, SubscriptionContext},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{broadcast, mpsc},
    time::timeout,
};
use tokio_util::sync::CancellationToken;

pub const DEFAULT_NATIVE_HOST: &str = "127.0.0.1";
pub const DEFAULT_NATIVE_PORT: u16 = 30006;
pub const DEFAULT_HTTP_ADDR: &str = "127.0.0.1:30007";
pub const MAX_NATIVE_FRAME: usize = 16 * 1024 * 1024;
pub const NATIVE_TIMEOUT: Duration = Duration::from_secs(30);
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NativeExpect {
    pub instance: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation: Option<String>,
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
    fn call(
        &self,
        tool: String,
        input: Value,
        expect: NativeExpect,
    ) -> BoxFuture<'static, Result<NativeResponse>>;
}

#[derive(Clone)]
pub struct NativeTcpClient {
    host: String,
    port: u16,
    timeout: Duration,
    slots: Arc<tokio::sync::Semaphore>,
}

impl NativeTcpClient {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
            timeout: NATIVE_TIMEOUT,
            slots: Arc::new(tokio::sync::Semaphore::new(4)),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout.max(Duration::from_secs(30));
        self
    }

    async fn request(&self, mut request: Value, budget: Duration) -> Result<NativeResponse> {
        let id = uuid::Uuid::new_v4().to_string();
        request["id"] = json!(id);
        let route = request["route"].as_str().unwrap_or_default().to_owned();
        let bytes = serde_json::to_vec(&request)?;
        if bytes.len() >= MAX_NATIVE_FRAME {
            return Err(anyhow!(
                "native request exceeds {MAX_NATIVE_FRAME} byte bound"
            ));
        }
        timeout(budget, async {
            let _slot = self.slots.acquire().await?;
            let mut stream = TcpStream::connect((self.host.as_str(), self.port)).await?;
            stream.set_nodelay(true)?;
            stream.write_all(&bytes).await?;
            stream.write_all(b"\n").await?;
            stream.flush().await?;
            let frame = read_frame(&mut stream, MAX_NATIVE_FRAME).await?;
            let response: NativeResponse =
                serde_json::from_slice(&frame).context("decode native response")?;
            if response.id != json!(id) || response.route != route {
                return Err(anyhow!("native response id or route mismatch"));
            }
            Ok(response)
        })
        .await
        .context("native deadline exceeded; outcome unknown; request was not replayed")?
    }
}

impl NativeBackend for NativeTcpClient {
    fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move {
            client
                .request(json!({"route":"status"}), client.timeout)
                .await
        })
    }

    fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move {
            client
                .request(json!({"route":"catalog"}), client.timeout)
                .await
        })
    }

    fn call(
        &self,
        tool: String,
        input: Value,
        expect: NativeExpect,
    ) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move {
            client
                .request(
                    json!({"route":"call","tool":tool,"input":input,"expect":expect}),
                    client.timeout,
                )
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

#[derive(Clone)]
pub struct CatalogSnapshot {
    pub identity: CatalogIdentity,
    pub tools: BTreeMap<String, NativeTool>,
    validators: BTreeMap<String, Arc<Validator>>,
}

impl CatalogSnapshot {
    fn decode(response: NativeResponse) -> Result<NativeCatalog> {
        anyhow::ensure!(response.ok, "native catalog failed: {}", response.error);
        let catalog: NativeCatalog = serde_json::from_value(response.data)?;
        anyhow::ensure!(
            catalog.schema_version == 1,
            "unsupported catalog schemaVersion"
        );
        anyhow::ensure!(
            !catalog.instance.is_empty() && !catalog.revision.is_empty(),
            "empty catalog identity"
        );
        anyhow::ensure!(
            catalog.tools.len() <= 8192,
            "too many native tool descriptors"
        );
        Ok(catalog)
    }

    fn compile(catalog: NativeCatalog) -> Result<Self> {
        let mut tools = BTreeMap::new();
        let mut validators = BTreeMap::new();
        for tool in catalog.tools {
            anyhow::ensure!(
                !tool.name.is_empty() && tool.name.len() <= 256,
                "invalid tool name"
            );
            anyhow::ensure!(
                !tools.contains_key(&tool.name),
                "duplicate native tool name"
            );
            anyhow::ensure!(
                tool.generation
                    .as_ref()
                    .is_none_or(|generation| !generation.is_empty()),
                "empty pack generation"
            );
            let validator = compile_schema(&tool.input_schema)
                .with_context(|| format!("schema for {}", tool.name))?;
            validators.insert(tool.name.clone(), Arc::new(validator));
            tools.insert(tool.name.clone(), tool);
        }
        Ok(Self {
            identity: CatalogIdentity {
                schema_version: catalog.schema_version,
                instance: catalog.instance,
                revision: catalog.revision,
            },
            tools,
            validators,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum CallError {
    #[error("unknown tool: {0}")]
    UnknownTool(String),
    #[error("invalid tool input: {0}")]
    InvalidArguments(String),
    #[error("native catalog unavailable: {0}")]
    CatalogUnavailable(String),
    #[error("native transport failed; outcome unknown; request was not replayed: {0}")]
    NativeTransport(String),
    #[error("invalid native tool response: {0}")]
    NativeProtocol(String),
}

pub struct Core {
    backend: Arc<dyn NativeBackend>,
    catalog: std::sync::RwLock<Option<CatalogSnapshot>>,
    refresh_lock: tokio::sync::Mutex<()>,
    catalog_changes: tokio::sync::watch::Sender<Option<CatalogIdentity>>,
    monitor: Arc<MonitorStore>,
}

impl Core {
    pub fn new(backend: Arc<dyn NativeBackend>, monitor: Arc<MonitorStore>) -> Arc<Self> {
        let (catalog_changes, _) = tokio::sync::watch::channel(None);
        Arc::new(Self {
            backend,
            catalog: std::sync::RwLock::new(None),
            refresh_lock: tokio::sync::Mutex::new(()),
            catalog_changes,
            monitor,
        })
    }

    pub fn monitor(&self) -> Arc<MonitorStore> {
        self.monitor.clone()
    }

    fn cached_catalog(&self) -> Option<CatalogSnapshot> {
        self.catalog.read().expect("catalog lock poisoned").clone()
    }

    pub fn catalog_updates(&self) -> tokio::sync::watch::Receiver<Option<CatalogIdentity>> {
        self.catalog_changes.subscribe()
    }

    // Caller holds refresh_lock. Compilation is atomic and never occupies an
    // async runtime thread; an invalid new schema preserves the previous cache.
    async fn install_catalog(&self, response: NativeResponse) -> Result<CatalogSnapshot> {
        let catalog = CatalogSnapshot::decode(response)?;
        let identity = CatalogIdentity {
            schema_version: catalog.schema_version,
            instance: catalog.instance.clone(),
            revision: catalog.revision.clone(),
        };
        if let Some(old) = self.cached_catalog() {
            if old.identity == identity {
                return Ok(old);
            }
        }
        let snapshot =
            tokio::task::spawn_blocking(move || CatalogSnapshot::compile(catalog)).await??;
        *self.catalog.write().expect("catalog lock poisoned") = Some(snapshot.clone());
        self.catalog_changes.send_replace(Some(identity));
        self.monitor
            .catalog_changed(snapshot.identity.revision.clone());
        Ok(snapshot)
    }

    pub async fn refresh_catalog(&self) -> Result<CatalogSnapshot> {
        let _guard = self.refresh_lock.lock().await;
        self.install_catalog(self.backend.catalog().await?).await
    }

    /// Cheap status probes fetch the full catalog only on an instance/revision
    /// change. A failed probe leaves discovery cached but never admits a call.
    pub async fn poll_catalog(&self) -> Result<CatalogSnapshot> {
        let _guard = self.refresh_lock.lock().await;
        let response = self.backend.status().await?;
        anyhow::ensure!(response.ok, "native status failed: {}", response.error);
        let identity: CatalogIdentity = serde_json::from_value(
            response
                .data
                .get("catalog")
                .cloned()
                .context("status has no catalog identity")?,
        )?;
        anyhow::ensure!(
            identity.schema_version == 1,
            "unsupported catalog schemaVersion"
        );
        if let Some(old) = self.cached_catalog() {
            if old.identity == identity {
                return Ok(old);
            }
        }
        self.install_catalog(self.backend.catalog().await?).await
    }

    /// Discovery can retain its last detached snapshot during a native outage.
    pub async fn catalog(&self) -> Result<CatalogSnapshot> {
        if let Some(catalog) = self.cached_catalog() {
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
        // Keep the old constructor surface for launchers; polling is at most 1s.
        let normal_delay = interval.clamp(Duration::from_millis(100), Duration::from_secs(1));
        tokio::spawn(async move {
            let mut delay = normal_delay;
            loop {
                let result = tokio::select! {
                    _ = cancellation.cancelled() => break,
                    result = core.poll_catalog() => result,
                };
                delay = match result {
                    Ok(_) => normal_delay,
                    Err(error) => {
                        tracing::debug!(%error, "catalog status probe failed");
                        delay.saturating_mul(2).min(Duration::from_secs(5))
                    }
                };
                tokio::select! {
                    _ = cancellation.cancelled() => break,
                    _ = tokio::time::sleep(delay) => {}
                }
            }
        });
    }

    pub async fn status(&self) -> Result<NativeResponse> {
        self.backend.status().await
    }

    async fn call_inner(
        &self,
        tool: &str,
        input: Value,
    ) -> std::result::Result<NativeResponse, CallError> {
        let catalog = self
            .poll_catalog()
            .await
            .map_err(|error| CallError::CatalogUnavailable(format!("{error:#}")))?;
        let descriptor = catalog
            .tools
            .get(tool)
            .ok_or_else(|| CallError::UnknownTool(tool.to_owned()))?;
        let validator = catalog
            .validators
            .get(tool)
            .expect("validated descriptor lacks validator")
            .clone();
        let expect = NativeExpect {
            instance: catalog.identity.instance.clone(),
            generation: descriptor.generation.clone(),
        };
        let validation_input = input.clone();
        tokio::task::spawn_blocking(move || {
            validator
                .validate(&validation_input)
                .map_err(|error| CallError::InvalidArguments(error.to_string()))
        })
        .await
        .map_err(|error| CallError::InvalidArguments(error.to_string()))??;
        let response = self
            .backend
            .call(tool.to_owned(), input, expect)
            .await
            .map_err(|error| CallError::NativeTransport(format!("{error:#}")))?;
        if response.ok
            && !response
                .data
                .pointer("/result/success")
                .is_some_and(Value::is_boolean)
        {
            return Err(CallError::NativeProtocol(
                "missing data.result.success boolean".into(),
            ));
        }
        Ok(response)
    }

    pub async fn call(
        &self,
        tool: &str,
        input: Value,
        connection_id: &str,
        request_id: &str,
    ) -> std::result::Result<NativeResponse, CallError> {
        let mut event = Event {
            invocation_id: self.monitor.next_id(),
            connection_id: bounded(connection_id),
            request_id: bounded(request_id),
            method: "tools/call".into(),
            tool: Some(bounded(tool)),
            started_ms: now_ms(),
            ended_ms: 0,
            status: "started".into(),
            argument_bytes: serde_json::to_vec(&input).map(|v| v.len()).unwrap_or(0),
            result_bytes: 0,
            arguments: bounded_json(&sanitize_value(&input)),
            result: String::new(),
        };
        self.monitor.record(event.clone());
        let result = self.call_inner(tool, input).await;
        event.ended_ms = now_ms();
        event.status = match &result {
            Ok(response) if !native_failed(response) => "ok",
            Ok(_) => "tool_error",
            Err(CallError::InvalidArguments(_)) => "invalid_arguments",
            Err(CallError::UnknownTool(_)) => "unknown_tool",
            Err(CallError::CatalogUnavailable(_)) => "catalog_unavailable",
            Err(_) => "transport_error",
        }
        .into();
        let data = match &result {
            Ok(response) => serde_json::to_value(response).unwrap_or(Value::Null),
            Err(error) => json!({"error":error.to_string()}),
        };
        event.result_bytes = serde_json::to_vec(&data).map(|v| v.len()).unwrap_or(0);
        event.result = bounded_json(&sanitize_value(&data));
        self.monitor.record(event);
        result
    }

    /// Real native documentation; resource handlers never manufacture content.
    pub async fn list_guides(
        &self,
        connection_id: &str,
        request_id: &str,
    ) -> Result<Vec<NativeGuide>> {
        let response = self
            .call("ListGuides", json!({}), connection_id, request_id)
            .await?;
        anyhow::ensure!(!native_failed(&response), "native ListGuides failed");
        serde_json::from_value(
            response
                .data
                .pointer("/result/output/guides")
                .cloned()
                .context("ListGuides has no guides array")?,
        )
        .context("decode native guides")
    }

    pub async fn get_guide(
        &self,
        topic: &str,
        connection_id: &str,
        request_id: &str,
    ) -> Result<Value> {
        let response = self
            .call(
                "GetGuide",
                json!({"topic":topic}),
                connection_id,
                request_id,
            )
            .await?;
        anyhow::ensure!(
            !native_failed(&response),
            "native GetGuide failed: {}",
            response.data
        );
        response
            .data
            .pointer("/result/output")
            .cloned()
            .context("GetGuide has no output")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeGuide {
    pub topic: String,
    pub title: String,
}

fn native_failed(response: &NativeResponse) -> bool {
    !response.ok || response.data.pointer("/result/success") == Some(&Value::Bool(false))
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

struct DenyExternalReferences;

impl jsonschema::Retrieve for DenyExternalReferences {
    fn retrieve(
        &self,
        _uri: &jsonschema::Uri<String>,
    ) -> std::result::Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        Err("external schema references are disabled".into())
    }
}

fn compile_schema(schema: &Value) -> Result<Validator> {
    anyhow::ensure!(schema.is_object(), "tool schema must be a JSON object");
    jsonschema::options()
        .with_draft(Draft::Draft202012)
        .with_retriever(DenyExternalReferences)
        .build(schema)
        .context("compile tool input schema")
}

pub fn validate_input(schema: &Value, input: &Value) -> Result<()> {
    compile_schema(schema)?
        .validate(input)
        .map_err(|error| anyhow!("invalid tool input: {error}"))
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
}

impl ServerHandler for McpAdapter {
    fn get_info(&self) -> ServerConfig {
        let mut resources = ResourcesCapability::default();
        resources.subscribe = Some(true);
        resources.list_changed = Some(true);
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources_with(resources).enable_tool_list_changed().build())
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

    fn get_tool(&self, name: &str) -> Option<Tool> {
        self.core.cached_catalog().and_then(|catalog| {
            catalog.tools.get(name).map(|tool| {
                let schema = tool.input_schema.as_object().cloned().unwrap_or_default();
                Tool::new_with_raw(
                    tool.name.clone(),
                    Some(tool.description.clone().into()),
                    Arc::new(schema),
                )
            })
        })
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
            Ok(response) => {
                let failed = native_failed(&response);
                Ok(native_result(response, failed).into())
            }
            Err(CallError::UnknownTool(error)) => Err(McpError::invalid_params(error, None)),
            Err(CallError::InvalidArguments(error)) => {
                Ok(CallToolResult::structured_error(json!({
                    "ok": false, "error": error, "code": "invalid_input"
                }))
                .into())
            }
            Err(error) => Ok(CallToolResult::structured_error(json!({
                "ok": false, "error": error.to_string(), "code": "native_transport"
            }))
            .into()),
        }
    }

    async fn list_resources(
        &self,
        _request: Option<rmcp::model::PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        let guides = self
            .core
            .list_guides("mcp", "resources/list")
            .await
            .map_err(internal_error)?;
        let resources = guides
            .into_iter()
            .map(|guide| {
                Resource::new(format!("tm-control://guide/{}", guide.topic), guide.topic)
                    .with_title(guide.title)
                    .with_mime_type("text/markdown")
                    .with_description("Native tm-control-mcp guide")
            })
            .collect();
        Ok(ListResourcesResult::with_all_items(resources)
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
        let output = self
            .core
            .get_guide(key, "mcp", &request.uri)
            .await
            .map_err(|error| McpError::resource_not_found(error.to_string(), None))?;
        let body = output
            .get("body")
            .and_then(Value::as_str)
            .ok_or_else(|| McpError::resource_not_found("native guide has no body", None))?;
        Ok(
            ReadResourceResult::new(vec![ResourceContents::text(body.to_owned(), request.uri)])
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
                        let _ = context.sink().notify_resource_list_changed().await;
                    }
                    Ok(CoreEvent::Invocation(_)) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
        }
    }

    async fn on_initialized(&self, context: rmcp::service::NotificationContext<RoleServer>) {
        let legacy = context
            .peer
            .peer_info()
            .map(|info| info.protocol_version != rmcp::model::ProtocolVersion::V_2026_07_28)
            .unwrap_or(true);
        if !legacy {
            return;
        }
        let mut changes = self.core.catalog_updates();
        let peer = context.peer;
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = changes.changed() => {
                        if changed.is_err() || peer.is_transport_closed() { break; }
                        let _ = peer.notify_tool_list_changed().await;
                        let _ = peer.notify_resource_list_changed().await;
                    }
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {
                        if peer.is_transport_closed() { break; }
                    }
                }
            }
        });
    }

    #[allow(deprecated)]
    async fn subscribe(
        &self,
        request: SubscribeRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<(), McpError> {
        request
            .uri
            .strip_prefix("tm-control://guide/")
            .filter(|topic| !topic.is_empty())
            .ok_or_else(|| {
                McpError::invalid_params("legacy subscribe requires a tm-control guide URI", None)
            })?;
        Ok(())
    }

    #[allow(deprecated)]
    async fn unsubscribe(
        &self,
        request: UnsubscribeRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<(), McpError> {
        request
            .uri
            .strip_prefix("tm-control://guide/")
            .filter(|topic| !topic.is_empty())
            .ok_or_else(|| {
                McpError::invalid_params("legacy unsubscribe requires a tm-control guide URI", None)
            })?;
        Ok(())
    }
}

fn request_id(id: &rmcp::model::RequestId) -> String {
    serde_json::to_string(id).unwrap_or_else(|_| "unknown".into())
}
fn internal_error(error: anyhow::Error) -> McpError {
    McpError::internal_error(error.to_string(), None)
}

fn native_result(response: NativeResponse, error: bool) -> CallToolResult {
    let output = serde_json::to_value(response).unwrap_or(Value::Null);
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
                    data: json!({"alive":true,"catalog":{"schemaVersion":1,"instance":"fake","revision":"1"}}),
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
                    data: json!({"schemaVersion":1,"instance":"fake","revision":"1","tools":[{"name":"Echo","description":"echo","input_schema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false},"pack":"","generation":null}]}),
                })
            })
        }
        fn call(
            &self,
            _tool: String,
            input: Value,
            expect: NativeExpect,
        ) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async move {
                assert_eq!(expect.instance, "fake");
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

    #[test]
    fn native_failure_is_tool_error_and_structured_content_keeps_envelope() {
        let response = NativeResponse {
            ok: true,
            id: json!("call-1"),
            route: "call".into(),
            error: String::new(),
            data: json!({"tool":"Echo","result":{"success":false,"error":"native failure","code":"failed"}}),
        };
        let result = native_result(response, true);
        assert_eq!(result.is_error, Some(true));
        assert_eq!(
            result.structured_content.unwrap()["data"]["result"]["success"],
            false
        );
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
            NativeResponse {
                ok: false,
                id: Value::Null,
                route: "call".into(),
                error: "unknown tool".into(),
                data: json!({"result":{"success":false,"output":{"fullName":"GameData/ScreenShot01.jpg"}}}),
            },
            true,
        );
        assert_eq!(output.is_error, Some(true));
        assert_eq!(
            output.structured_content.unwrap()["data"]["result"]["success"],
            false
        );
    }
}

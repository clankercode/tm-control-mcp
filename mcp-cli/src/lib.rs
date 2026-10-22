//! Shared core for the `mcp-cli` binary.

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Duration,
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
        ToolAnnotations, UnsubscribeRequestParams,
    },
    service::{RequestContext, SubscriptionContext},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};
use tokio_util::sync::CancellationToken;

pub const DEFAULT_NATIVE_HOST: &str = "127.0.0.1";
pub const DEFAULT_NATIVE_PORT: u16 = 30006;
pub const DEFAULT_HTTP_ADDR: &str = "127.0.0.1:30007";
pub const MAX_NATIVE_FRAME: usize = 16 * 1024 * 1024;
pub const NATIVE_TIMEOUT: Duration = Duration::from_secs(30);
pub mod media;
pub mod monitor;
pub use monitor::{CoreEvent, Event, MAX_EVENT_COPY, MAX_EVENTS, MonitorStats, MonitorStore};
use monitor::{bounded, bounded_json, now_ms, sanitize_value};
pub const MAX_ACTIVE_CALLS: usize = 8;

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<ToolAnnotations>,
    #[serde(
        rename = "output_schema",
        alias = "outputSchema",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub output_schema: Option<Value>,
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

pub trait NativeBackend: Send + Sync {
    fn status(&self) -> BoxFuture<'static, Result<NativeResponse>>;
    fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>>;
    fn call(
        &self,
        tool: String,
        input: Value,
        expect: Option<NativeExpect>,
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
        expect: Option<NativeExpect>,
    ) -> BoxFuture<'static, Result<NativeResponse>> {
        let client = self.clone();
        Box::pin(async move {
            let mut request = json!({"route":"call","tool":tool,"input":input});
            if let Some(expect) = expect {
                request["expect"] = serde_json::to_value(expect)?;
            }
            client.request(request, client.timeout).await
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
            anyhow::ensure!(
                tool.output_schema.as_ref().is_none_or(Value::is_object),
                "output schema for {} must be a JSON object",
                tool.name
            );
            if let Some(schema) = &tool.output_schema {
                compile_schema(&envelope_output_schema(schema.clone()))
                    .with_context(|| format!("output schema for {}", tool.name))?;
            }
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
    #[error("native call queue is full")]
    QueueFull,
    #[error(
        "native call cancelled; an already dispatched operation may still run; outcome unknown; request was not replayed"
    )]
    Cancelled,
    #[error("invalid native tool response: {0}")]
    NativeProtocol(String),
}

pub struct Core {
    backend: Arc<dyn NativeBackend>,
    catalog: std::sync::RwLock<Option<CatalogSnapshot>>,
    refresh_lock: tokio::sync::Mutex<()>,
    catalog_changes: tokio::sync::watch::Sender<Option<CatalogIdentity>>,
    monitor: Arc<MonitorStore>,
    call_slots: Arc<tokio::sync::Semaphore>,
    guides: std::sync::RwLock<Option<GuideCache>>,
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
            call_slots: Arc::new(tokio::sync::Semaphore::new(MAX_ACTIVE_CALLS)),
            guides: std::sync::RwLock::new(None),
        })
    }

    pub fn monitor(&self) -> Arc<MonitorStore> {
        self.monitor.clone()
    }

    pub fn backend(&self) -> Arc<dyn NativeBackend> {
        self.backend.clone()
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
        *self.guides.write().expect("guide cache lock poisoned") = None;
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
        cancellation: &CancellationToken,
    ) -> std::result::Result<NativeResponse, CallError> {
        let _slot = self
            .call_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| CallError::QueueFull)?;
        let catalog = tokio::select! {
            _ = cancellation.cancelled() => Err(CallError::Cancelled),
            result = self.poll_catalog() => result
                .map_err(|error| CallError::CatalogUnavailable(format!("{error:#}"))),
        }?;
        let descriptor = catalog
            .tools
            .get(tool)
            .ok_or_else(|| CallError::UnknownTool(tool.to_owned()))?;
        let validator = catalog
            .validators
            .get(tool)
            .expect("validated descriptor lacks validator")
            .clone();
        let expect = Some(NativeExpect {
            instance: catalog.identity.instance.clone(),
            generation: descriptor.generation.clone(),
        });
        let validation_input = input.clone();
        let validation = tokio::task::spawn_blocking(move || {
            validator
                .validate(&validation_input)
                .map_err(|error| CallError::InvalidArguments(error.to_string()))
        });
        tokio::select! {
            _ = cancellation.cancelled() => return Err(CallError::Cancelled),
            result = validation => result
                .map_err(|error| CallError::InvalidArguments(error.to_string()))??,
        }
        let response = tokio::select! {
            _ = cancellation.cancelled() => return Err(CallError::Cancelled),
            result = self.backend.call(tool.to_owned(), input, expect) => result
                .map_err(|error| CallError::NativeTransport(format!("{error:#}")))?,
        };
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
        self.call_with_cancellation(
            tool,
            input,
            connection_id,
            request_id,
            CancellationToken::new(),
        )
        .await
    }

    pub async fn call_with_cancellation(
        &self,
        tool: &str,
        input: Value,
        connection_id: &str,
        request_id: &str,
        cancellation: CancellationToken,
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
        let result = self.call_inner(tool, input, &cancellation).await;
        event.ended_ms = now_ms();
        event.status = match &result {
            Ok(response) if !native_failed(response) => "ok",
            Ok(_) => "tool_error",
            Err(CallError::InvalidArguments(_)) => "invalid_arguments",
            Err(CallError::UnknownTool(_)) => "unknown_tool",
            Err(CallError::CatalogUnavailable(_)) => "catalog_unavailable",
            Err(CallError::QueueFull) => "queue_full",
            Err(CallError::Cancelled) => "cancelled",
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
        if let Some(cache) = self
            .guides
            .read()
            .expect("guide cache lock poisoned")
            .clone()
        {
            if let Some(guides) = cache.guides {
                return Ok(guides);
            }
        }
        let response = self
            .call("ListGuides", json!({}), connection_id, request_id)
            .await?;
        anyhow::ensure!(!native_failed(&response), "native ListGuides failed");
        let guides: Vec<NativeGuide> = serde_json::from_value(
            response
                .data
                .pointer("/result/output/guides")
                .cloned()
                .context("ListGuides has no guides array")?,
        )
        .context("decode native guides")?;
        anyhow::ensure!(guides.len() <= 256, "too many native guides");
        let mut seen = std::collections::BTreeSet::new();
        for guide in &guides {
            anyhow::ensure!(
                !guide.topic.is_empty() && seen.insert(guide.topic.clone()),
                "invalid or duplicate native guide topic"
            );
        }
        self.guides
            .write()
            .expect("guide cache lock poisoned")
            .get_or_insert_with(GuideCache::default)
            .guides = Some(guides.clone());
        Ok(guides)
    }

    pub async fn get_guide(
        &self,
        topic: &str,
        connection_id: &str,
        request_id: &str,
    ) -> Result<Value> {
        if let Some(body) = self
            .guides
            .read()
            .expect("guide cache lock poisoned")
            .as_ref()
            .and_then(|cache| cache.bodies.get(topic).cloned())
        {
            return Ok(body);
        }
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
        let output = response
            .data
            .pointer("/result/output")
            .cloned()
            .context("GetGuide has no output")?;
        self.guides
            .write()
            .expect("guide cache lock poisoned")
            .get_or_insert_with(GuideCache::default)
            .bodies
            .insert(topic.to_owned(), output.clone());
        Ok(output)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeGuide {
    pub topic: String,
    pub title: String,
}

#[derive(Debug, Clone, Default)]
struct GuideCache {
    guides: Option<Vec<NativeGuide>>,
    bodies: BTreeMap<String, Value>,
}

fn native_failed(response: &NativeResponse) -> bool {
    !response.ok || response.data.pointer("/result/success") == Some(&Value::Bool(false))
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

pub struct McpAdapter {
    pub core: Arc<Core>,
    media: Option<Arc<media::MediaService>>,
    connection_id: String,
    legacy_subscriptions: Arc<Mutex<std::collections::BTreeSet<String>>>,
    legacy_started: Arc<std::sync::atomic::AtomicBool>,
}

impl Clone for McpAdapter {
    fn clone(&self) -> Self {
        // The HTTP service factory clones the template for each legacy session
        // or modern stateless exchange; each receives its own observer identity.
        let mut adapter = Self::new(self.core.clone());
        adapter.media = self.media.clone();
        adapter
    }
}

impl McpAdapter {
    pub fn new(core: Arc<Core>) -> Self {
        let media = media::MediaService::from_environment(core.backend()).ok();
        Self {
            core,
            media,
            connection_id: uuid::Uuid::new_v4().to_string(),
            legacy_subscriptions: Arc::new(Mutex::new(std::collections::BTreeSet::new())),
            legacy_started: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    pub fn with_media_root(core: Arc<Core>, root: Option<std::path::PathBuf>) -> Result<Self> {
        let mut adapter = Self::new(core);
        if let Some(root) = root {
            adapter.media = Some(media::MediaService::new(
                adapter.core.backend(),
                media::ScreenshotConfig::new(root)?,
            ));
        }
        Ok(adapter)
    }

    fn tools(&self, catalog: CatalogSnapshot) -> Vec<Tool> {
        catalog
            .tools
            .into_values()
            .map(Self::tool_from_descriptor)
            .collect()
    }

    fn tool_from_descriptor(tool: NativeTool) -> Tool {
        let input_schema = Arc::new(
            tool.input_schema
                .as_object()
                .expect("catalog compiler validates input schemas")
                .clone(),
        );
        let mut output = Tool::new_with_raw(tool.name, Some(tool.description.into()), input_schema);
        if let Some(schema) = tool.output_schema {
            output = output.with_raw_output_schema(Arc::new(
                envelope_output_schema(schema)
                    .as_object()
                    .expect("wrapper schema is an object")
                    .clone(),
            ));
        }
        if let Some(annotations) = tool.annotations {
            output = output.with_annotations(annotations);
        }
        output
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
            catalog
                .tools
                .get(name)
                .cloned()
                .map(McpAdapter::tool_from_descriptor)
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
        let capture = if tool == "TakeScreenshot" {
            let Some(media) = &self.media else {
                return Ok(CallToolResult::structured_error(json!({"code":"screenshot_mapping_missing", "error":"Configure --screenshots-dir or TM_USER_GAME_FOLDER for fresh image capture"})).into());
            };
            match media.prepare().await {
                Ok(capture) => Some(capture),
                Err(error) => {
                    return Ok(CallToolResult::structured_error(
                        json!({"code":"screenshot_capture", "error":error.to_string()}),
                    )
                    .into());
                }
            }
        } else {
            None
        };
        let result = self
            .core
            .call_with_cancellation(
                &tool,
                input,
                &self.connection_id,
                &request_id(&context.id),
                context.ct.clone(),
            )
            .await;
        if let (Ok(mut response), Some(capture), Some(media)) =
            (result.as_ref().cloned(), capture, &self.media)
        {
            if !native_failed(&response) {
                match media.finish(capture, &response).await {
                    Ok(artifact) => {
                        if let Some(output) = response.data.pointer_mut("/result/output").and_then(Value::as_object_mut) {
                            output.insert("screenshot".into(), json!({"uri":artifact.uri(),"mimeType":artifact.mime_type(),"size":artifact.size_bytes(),"immutable":true}));
                        }
                        let mut result = native_result(response, false);
                        result.content.push(artifact.image_block());
                        return Ok(result.into());
                    }
                    Err(error) => return Ok(CallToolResult::structured_error(json!({"code":"screenshot_capture", "error":error.to_string(),"native":response})).into()),
                }
            }
        }
        map_call_result(result)
    }

    async fn list_resources(
        &self,
        _request: Option<rmcp::model::PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        let guides = self
            .core
            .list_guides(&self.connection_id, "resources/list")
            .await
            .map_err(internal_error)?;
        let mut resources = guides
            .into_iter()
            .map(|guide| {
                Resource::new(format!("tm-control://guide/{}", guide.topic), guide.topic)
                    .with_title(guide.title)
                    .with_mime_type("text/markdown")
                    .with_description("Native tm-control-mcp guide")
            })
            .collect::<Vec<_>>();
        if let Some(media) = &self.media {
            resources.extend(media.list_image_resources());
        }
        Ok(ListResourcesResult::with_all_items(resources)
            .with_ttl_ms(0)
            .with_cache_scope(CacheScope::Private))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, McpError> {
        if request.uri.starts_with(media::SCREENSHOT_URI_PREFIX) {
            let media = self
                .media
                .as_ref()
                .ok_or_else(|| McpError::resource_not_found(request.uri.clone(), None))?;
            return Ok(ReadResourceResult::new(vec![
                media
                    .read_image_resource(&request.uri)
                    .map_err(internal_error)?,
            ])
            .with_ttl_ms(0)
            .with_cache_scope(CacheScope::Private)
            .into());
        }
        let prefix = "tm-control://guide/";
        if !valid_guide_uri(&request.uri) {
            return Err(McpError::resource_not_found(request.uri.clone(), None));
        }
        let key = request
            .uri
            .strip_prefix(prefix)
            .ok_or_else(|| McpError::resource_not_found(request.uri.clone(), None))?;
        let output = self
            .core
            .get_guide(key, &self.connection_id, &request.uri)
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
        let mut builder = SubscriptionFilter::builder()
            .tools_list_changed()
            .resources_list_changed();
        if let Some(uris) = &requested.resource_subscriptions {
            builder = builder.resource_subscriptions(
                uris.iter()
                    .filter(|uri| valid_guide_uri(uri))
                    .cloned()
                    .collect::<Vec<_>>(),
            );
        }
        Some(builder.build().intersection(requested))
    }

    async fn listen(&self, context: SubscriptionContext) -> Result<(), McpError> {
        // Catalog changes have their own coalescing channel so a busy/lossy
        // invocation monitor cannot cause missed cache invalidations.
        let mut changes = self.core.catalog_updates();
        loop {
            tokio::select! {
                _ = context.cancelled() => return Ok(()),
                changed = changes.changed() => {
                    if changed.is_err() { return Ok(()); }
                    let sink = context.sink();
                    let accepted = context.accepted();
                    let sent = timeout(Duration::from_secs(2), async {
                        if accepted.tools_list_changed == Some(true) { sink.notify_tool_list_changed().await?; }
                        if accepted.resources_list_changed == Some(true) { sink.notify_resource_list_changed().await?; }
                        if let Some(uris) = &accepted.resource_subscriptions {
                            for uri in uris { sink.notify_resource_updated(uri.clone()).await?; }
                        }
                        Ok::<_, rmcp::service::SubscriptionSendError>(())
                    }).await;
                    if !matches!(sent, Ok(Ok(()))) { return Ok(()); }
                }
            }
        }
    }

    async fn on_initialized(&self, context: rmcp::service::NotificationContext<RoleServer>) {
        let legacy = context
            .peer
            .peer_info()
            .is_some_and(|info| info.protocol_version.has_initialize());
        if !legacy
            || self
                .legacy_started
                .swap(true, std::sync::atomic::Ordering::AcqRel)
        {
            return;
        }
        let mut changes = self.core.catalog_updates();
        let subscriptions = self.legacy_subscriptions.clone();
        let peer = context.peer;
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = changes.changed() => {
                        if changed.is_err() || peer.is_transport_closed() { break; }
                        let uris: Vec<String> = subscriptions.lock().expect("subscription lock poisoned").iter().cloned().collect();
                        let sent = timeout(Duration::from_secs(2), async {
                            peer.notify_tool_list_changed().await?;
                            peer.notify_resource_list_changed().await?;
                            for uri in uris {
                                peer.notify_resource_updated(rmcp::model::ResourceUpdatedNotificationParam::new(uri)).await?;
                            }
                            Ok::<_, rmcp::service::ServiceError>(())
                        }).await;
                        if !matches!(sent, Ok(Ok(()))) { break; }
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
        context: RequestContext<RoleServer>,
    ) -> Result<(), McpError> {
        if !valid_guide_uri(&request.uri) {
            return Err(McpError::invalid_params(
                "legacy subscribe requires a tm-control guide URI",
                None,
            ));
        }
        self.core
            .get_guide(
                request
                    .uri
                    .strip_prefix("tm-control://guide/")
                    .unwrap_or_default(),
                &self.connection_id,
                &request_id(&context.id),
            )
            .await
            .map_err(internal_error)?;
        let mut subscriptions = self
            .legacy_subscriptions
            .lock()
            .expect("subscription lock poisoned");
        if subscriptions.len() >= 128 && !subscriptions.contains(&request.uri) {
            return Err(McpError::invalid_params(
                "too many guide subscriptions",
                None,
            ));
        }
        subscriptions.insert(request.uri);
        Ok(())
    }

    #[allow(deprecated)]
    async fn unsubscribe(
        &self,
        request: UnsubscribeRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<(), McpError> {
        if !valid_guide_uri(&request.uri) {
            return Err(McpError::invalid_params(
                "legacy unsubscribe requires a tm-control guide URI",
                None,
            ));
        }
        self.legacy_subscriptions
            .lock()
            .expect("subscription lock poisoned")
            .remove(&request.uri);
        Ok(())
    }
}

fn map_call_result(
    result: std::result::Result<NativeResponse, CallError>,
) -> std::result::Result<CallToolResponse, McpError> {
    match result {
        Ok(response) => {
            let failed = native_failed(&response);
            Ok(native_result(response, failed).into())
        }
        Err(CallError::UnknownTool(error)) => Err(McpError::invalid_params(error, None)),
        Err(CallError::InvalidArguments(error)) => Ok(CallToolResult::structured_error(json!({
            "ok": false, "error": error, "code": "invalid_input"
        }))
        .into()),
        Err(error) => Ok(CallToolResult::structured_error(json!({
            "ok": false, "error": error.to_string(), "code": "native_transport"
        }))
        .into()),
    }
}

fn request_id(id: &rmcp::model::RequestId) -> String {
    serde_json::to_string(id).unwrap_or_else(|_| "unknown".into())
}

fn valid_guide_uri(uri: &str) -> bool {
    uri.strip_prefix("tm-control://guide/")
        .is_some_and(|topic| !topic.is_empty() && !topic.contains('/'))
}

fn internal_error(error: anyhow::Error) -> McpError {
    McpError::internal_error(error.to_string(), None)
}

/// Native metadata describes `result.output`; MCP structured content includes
/// the complete response envelope. A nested resource preserves local $refs.
fn envelope_output_schema(mut payload: Value) -> Value {
    if let Some(schema) = payload.as_object_mut() {
        schema
            .entry("$id")
            .or_insert(json!("urn:tm-control-mcp:output-payload"));
    }
    json!({
        "type":"object",
        "required":["ok"],
        "properties":{
            "ok":{"type":"boolean"},
            "error":{"type":"string"},
            "data":{"type":"object","required":["result"],"properties":{
                "result":{"type":"object","required":["success"],"properties":{"success":{"type":"boolean"}},
                    "if":{"properties":{"success":{"const":true}}},
                    "then":{"required":["output"],"properties":{"output":payload}}}
            }}
        },
        "if":{"properties":{"ok":{"const":true}}},
        "then":{"required":["data"]}
    })
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
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::Notify;

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
            expect: Option<NativeExpect>,
        ) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async move {
                assert_eq!(
                    expect.as_ref().map(|value| value.instance.as_str()),
                    Some("fake")
                );
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
    fn catalog_preserves_raw_tool_metadata_and_schemas() {
        let input_schema = json!({
            "type": "object",
            "properties": {"value": {"type": "integer", "minimum": 1}},
            "required": ["value"],
            "additionalProperties": false
        });
        let output_schema = json!({
            "type": "object",
            "properties": {"ok": {"const": true}},
            "required": ["ok"]
        });
        let snapshot = CatalogSnapshot::compile(NativeCatalog {
            schema_version: 1,
            instance: "instance".into(),
            revision: "revision".into(),
            tools: vec![NativeTool {
                name: "Meta".into(),
                description: "metadata".into(),
                input_schema: input_schema.clone(),
                pack: "pack".into(),
                generation: Some("7".into()),
                annotations: Some(ToolAnnotations::new().read_only(true).idempotent(true)),
                output_schema: Some(output_schema.clone()),
            }],
        })
        .unwrap();
        let tool = McpAdapter::tool_from_descriptor(snapshot.tools["Meta"].clone());
        assert_eq!(tool.schema_as_json_value(), input_schema);
        assert_eq!(
            tool.output_schema
                .as_ref()
                .map(|schema| Value::Object(schema.as_ref().clone())),
            Some(envelope_output_schema(output_schema))
        );
        assert_eq!(
            tool.annotations.as_ref().unwrap().read_only_hint,
            Some(true)
        );
        assert_eq!(
            tool.annotations.as_ref().unwrap().idempotent_hint,
            Some(true)
        );
    }

    #[test]
    fn output_schema_validates_envelope_payload_and_local_references() {
        let payload = json!({"type":"object","$defs":{"answer":{"type":"string"}},
            "properties":{"pong":{"$ref":"#/$defs/answer"}},"required":["pong"],"additionalProperties":false});
        let schema = envelope_output_schema(payload);
        let validator = compile_schema(&schema).unwrap();
        assert!(validator.is_valid(
            &json!({"ok":true,"data":{"result":{"success":true,"output":{"pong":"yes"}}}})
        ));
        assert!(
            !validator.is_valid(&json!({"ok":true,"data":{"result":{"success":true,"output":{}}}}))
        );
        assert!(
            !validator.is_valid(
                &json!({"ok":true,"data":{"result":{"success":true,"output":{"pong":5}}}})
            )
        );
        assert!(
            validator
                .is_valid(&json!({"ok":true,"data":{"result":{"success":false,"error":"failed"}}}))
        );
        assert!(validator.is_valid(&json!({"ok":false,"error":"transport"})));
    }

    #[derive(Clone)]
    struct GuideBackend {
        calls: Arc<AtomicUsize>,
    }

    impl NativeBackend for GuideBackend {
        fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async {
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "status".into(),
                    error: String::new(),
                    data: json!({"catalog":{"schemaVersion":1,"instance":"guide","revision":"1"}}),
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
                    data: json!({
                        "schemaVersion": 1,
                        "instance": "guide",
                        "revision": "1",
                        "tools": [
                            {"name":"ListGuides","input_schema":{"type":"object"}},
                            {"name":"GetGuide","input_schema":{"type":"object","properties":{"topic":{"type":"string"}},"required":["topic"]}},
                        ]
                    }),
                })
            })
        }

        fn call(
            &self,
            tool: String,
            input: Value,
            _expect: Option<NativeExpect>,
        ) -> BoxFuture<'static, Result<NativeResponse>> {
            let calls = self.calls.clone();
            Box::pin(async move {
                calls.fetch_add(1, Ordering::Relaxed);
                let output = match tool.as_str() {
                    "ListGuides" => json!({"guides":[{"topic":"index","title":"Index"}]}),
                    "GetGuide" => {
                        json!({"topic":input["topic"],"title":"Index","body":"native body"})
                    }
                    _ => anyhow::bail!("unexpected tool"),
                };
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "call".into(),
                    error: String::new(),
                    data: json!({"result":{"success":true,"output":output}}),
                })
            })
        }
    }

    #[tokio::test]
    async fn native_guides_are_cached_after_backend_fetches() {
        let calls = Arc::new(AtomicUsize::new(0));
        let core = Core::new(
            Arc::new(GuideBackend {
                calls: calls.clone(),
            }),
            MonitorStore::new(None),
        );
        assert_eq!(
            core.list_guides("test", "1").await.unwrap()[0].topic,
            "index"
        );
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert_eq!(
            core.list_guides("test", "2").await.unwrap()[0].topic,
            "index"
        );
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert_eq!(
            core.get_guide("index", "test", "3").await.unwrap()["body"],
            "native body"
        );
        assert_eq!(calls.load(Ordering::Relaxed), 2);
        assert_eq!(
            core.get_guide("index", "test", "4").await.unwrap()["body"],
            "native body"
        );
        assert_eq!(calls.load(Ordering::Relaxed), 2);

        let reverse_calls = Arc::new(AtomicUsize::new(0));
        let reverse = Core::new(
            Arc::new(GuideBackend {
                calls: reverse_calls.clone(),
            }),
            MonitorStore::new(None),
        );
        reverse.get_guide("index", "test", "5").await.unwrap();
        assert_eq!(
            reverse.list_guides("test", "6").await.unwrap()[0].topic,
            "index"
        );
        assert_eq!(reverse_calls.load(Ordering::Relaxed), 2);
    }

    struct SlowBackend {
        started: Arc<AtomicUsize>,
        release: Arc<Notify>,
    }

    impl NativeBackend for SlowBackend {
        fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async {
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "status".into(),
                    error: String::new(),
                    data: json!({"catalog":{"schemaVersion":1,"instance":"slow","revision":"1"}}),
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
                    data: json!({"schemaVersion":1,"instance":"slow","revision":"1","tools":[{"name":"Slow","input_schema":{"type":"object"}}]}),
                })
            })
        }

        fn call(
            &self,
            _tool: String,
            _input: Value,
            _expect: Option<NativeExpect>,
        ) -> BoxFuture<'static, Result<NativeResponse>> {
            let started = self.started.clone();
            let release = self.release.clone();
            Box::pin(async move {
                started.fetch_add(1, Ordering::Relaxed);
                release.notified().await;
                Ok(NativeResponse {
                    ok: true,
                    id: Value::Null,
                    route: "call".into(),
                    error: String::new(),
                    data: json!({"result":{"success":true,"output":{}}}),
                })
            })
        }
    }

    #[tokio::test]
    async fn calls_have_bounded_admission_and_honor_cancellation() {
        let backend = Arc::new(SlowBackend {
            started: Arc::new(AtomicUsize::new(0)),
            release: Arc::new(Notify::new()),
        });
        let core = Core::new(backend.clone(), MonitorStore::new(None));
        let mut tasks = Vec::new();
        for index in 0..MAX_ACTIVE_CALLS {
            let core = core.clone();
            tasks.push(tokio::spawn(async move {
                core.call("Slow", json!({}), "test", &index.to_string())
                    .await
            }));
        }
        for _ in 0..100 {
            if backend.started.load(Ordering::Relaxed) == MAX_ACTIVE_CALLS {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(backend.started.load(Ordering::Relaxed), MAX_ACTIVE_CALLS);
        assert!(matches!(
            core.call("Slow", json!({}), "test", "full").await,
            Err(CallError::QueueFull)
        ));
        backend.release.notify_waiters();
        for task in tasks {
            assert!(task.await.unwrap().is_ok());
        }

        let token = CancellationToken::new();
        let core = core.clone();
        let cancel = token.clone();
        let task = tokio::spawn(async move {
            core.call_with_cancellation("Slow", json!({}), "test", "cancel", cancel)
                .await
        });
        for _ in 0..100 {
            if backend.started.load(Ordering::Relaxed) > MAX_ACTIVE_CALLS {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        token.cancel();
        assert!(matches!(task.await.unwrap(), Err(CallError::Cancelled)));
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

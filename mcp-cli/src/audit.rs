//! Read-only audit surface for Streamable HTTP listeners.
//!
//! Server half: `GET /monitor/snapshot` serves the same sanitized, bounded
//! monitor events the in-process TUI renders. Client half: `fetch_snapshot`
//! pulls one snapshot over loopback HTTP and `RemoteMonitor` keeps the latest
//! one fresh for an attached TUI. Both halves only ever talk to loopback.

use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::Json;
use axum::{
    Router,
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use tokio_util::sync::CancellationToken;

use crate::Event;
use crate::monitor::{MAX_EVENTS, MonitorStats, MonitorStore, clean_text, safe_payload};

pub const SERVER_NAME: &str = "tm-control-mcp";
pub const SNAPSHOT_PATH: &str = "/monitor/snapshot";
/// A snapshot is bounded by the store (~21 MiB retained); JSON escaping can
/// expand it, so the client refuses anything past this bound.
pub const MAX_SNAPSHOT_BYTES: usize = 128 * 1024 * 1024;
/// Defensive per-field cap mirroring the store's metadata bound.
const AUDIT_TEXT_BYTES: usize = 512;
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
pub const POLL_INTERVAL: Duration = Duration::from_millis(250);
pub const MAX_POLL_INTERVAL: Duration = Duration::from_secs(2);
const MAX_POLLED_EVENTS: usize = MAX_EVENTS * 2;

#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("attach target must be a loopback address: {0}")]
    NotLoopback(SocketAddr),
    #[error("no server answered at {0}: {1}")]
    Connect(SocketAddr, String),
    #[error("audit request to {0} timed out")]
    Timeout(SocketAddr),
    #[error("audit transport failure at {0}: {1}")]
    Transport(SocketAddr, String),
    #[error("audit endpoint at {0} answered HTTP {1}: {2}")]
    Status(SocketAddr, u16, String),
    #[error("endpoint at {0} is not a {SERVER_NAME} monitor")]
    NotMonitor(SocketAddr),
    #[error("audit snapshot from {0} is invalid: {1}")]
    Decode(SocketAddr, String),
}

impl FetchError {
    /// Actionable one-liner for a failed initial attach probe.
    pub fn attach_hint(&self, target: SocketAddr) -> String {
        match self {
            Self::NotLoopback(_) => format!(
                "use a loopback --attach target, or start your own listener with `tm-control-mcp monitor --serve`"
            ),
            Self::Connect(..) | Self::Timeout(_) => format!(
                "no tm-control-mcp HTTP server answered at {target}; start one with \
                 `tm-control-mcp serve --transport http --listen {target}` or run \
                 `tm-control-mcp monitor --serve`"
            ),
            Self::Status(_, 404, _) => format!(
                "the server at {target} has no {SNAPSHOT_PATH} endpoint; it is an older \
                 tm-control-mcp or a different service. Upgrade it, or run \
                 `tm-control-mcp monitor --serve`"
            ),
            Self::Status(_, 403, _) => format!(
                "the server at {target} refused the audit request; check its --origin policy"
            ),
            Self::NotMonitor(_) => format!(
                "the endpoint at {target}{SNAPSHOT_PATH} is not a {SERVER_NAME} monitor; \
                 check --attach or run `tm-control-mcp monitor --serve`"
            ),
            Self::Status(..) | Self::Transport(..) | Self::Decode(..) => {
                format!("{self}; use `tm-control-mcp monitor --serve` to start an auditable server")
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub server: String,
    pub version: String,
    /// Per-listener nonce; a change means the audited server process was
    /// replaced and its invocation ids no longer identify the same calls.
    #[serde(default)]
    pub instance: String,
    pub events: Vec<Event>,
    pub stats: MonitorStats,
}

// ---------------------------------------------------------------------------
// Server half
// ---------------------------------------------------------------------------

/// Store version the cached snapshot body is keyed on: every field that can
/// change the serialized snapshot bumps one of these counters.
type SnapshotVersion = (u64, u64, u64, u64);

#[derive(Debug, Clone)]
pub struct AuditState {
    pub monitor: Arc<MonitorStore>,
    /// Allowed `Host` header values, mirroring the MCP route's host policy.
    pub allowed_hosts: Vec<String>,
    /// Origins allowed by the audit route. Unlike rmcp's normalised,
    /// wildcard-aware `--origin` matching on `/mcp`, this check is a strict
    /// exact-string comparison — deliberately the stricter side of the pair.
    pub allowed_origins: Vec<String>,
    /// Per-listener nonce reported in snapshots (see [`Snapshot::instance`]).
    pub instance: String,
    /// Serialized body cached until the store version changes, so a merely
    /// attached monitor never costs the serving process per-poll work.
    /// Shared behind an `Arc` because axum clones the state per request.
    cache: Arc<Mutex<Option<(SnapshotVersion, Bytes)>>>,
}

impl AuditState {
    pub fn new(
        monitor: Arc<MonitorStore>,
        allowed_hosts: Vec<String>,
        allowed_origins: Vec<String>,
    ) -> Self {
        Self {
            monitor,
            allowed_hosts,
            allowed_origins,
            instance: uuid::Uuid::new_v4().to_string(),
            cache: Arc::new(Mutex::new(None)),
        }
    }
}

/// Host values the audit endpoint accepts: the bound IP (with or without
/// port) and `localhost:<port>`, mirroring the MCP route configuration.
/// `SocketAddr` display keeps IPv6 forms bracketed (`[::1]:30007`), which is
/// what the attach client sends in its `Host` header.
pub fn allowed_hosts(address: SocketAddr) -> Vec<String> {
    vec![
        address.ip().to_string(),
        address.to_string(),
        format!("localhost:{}", address.port()),
    ]
}

pub fn snapshot_value(store: &MonitorStore, instance: &str) -> Value {
    json!({
        "server": SERVER_NAME,
        "version": env!("CARGO_PKG_VERSION"),
        "instance": instance,
        "events": store.snapshot(),
        "stats": store.stats(),
    })
}

pub fn audit_router(state: AuditState) -> Router {
    Router::new()
        .route(SNAPSHOT_PATH, get(snapshot_handler))
        .with_state(state)
}

async fn snapshot_handler(State(state): State<AuditState>, headers: HeaderMap) -> Response {
    if let Some(rejection) = guard(&state, &headers) {
        return rejection;
    }
    let (version, body) = cached_body(&state);
    let etag = etag_value(version);
    (
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::ETAG, etag.as_str()),
            (header::CONTENT_TYPE, "application/json"),
        ],
        axum::body::Body::from(body),
    )
        .into_response()
}

fn snapshot_version(store: &MonitorStore) -> SnapshotVersion {
    let stats = store.stats();
    (
        stats.observed,
        stats.lagged,
        stats.jsonl_dropped,
        stats.jsonl_errors,
    )
}

/// Serialize at most once per store version; unchanged polls return the same
/// `Bytes` handle without cloning events or rebuilding JSON on the worker.
fn cached_body(state: &AuditState) -> (SnapshotVersion, Bytes) {
    let version = snapshot_version(&state.monitor);
    let mut cache = state.cache.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((cached_version, body)) = cache.as_ref() {
        if *cached_version == version {
            return (version, body.clone());
        }
    }
    let body = Bytes::from(
        serde_json::to_vec(&snapshot_value(&state.monitor, &state.instance))
            .unwrap_or_else(|_| b"{}".to_vec()),
    );
    *cache = Some((version, body.clone()));
    (version, body)
}

fn etag_value(version: SnapshotVersion) -> String {
    format!(
        "\"tm-control-mcp-{}-{}-{}-{}\"",
        version.0, version.1, version.2, version.3
    )
}

/// The audit route is read-only, but it serves the same sanitized payload
/// data as the TUI, so it keeps the MCP route's host and origin posture:
/// a present `Origin` must be explicitly allowed, and a present `Host`
/// must match the listener. Missing headers stay allowed for plain local
/// clients.
fn guard(state: &AuditState, headers: &HeaderMap) -> Option<Response> {
    if let Some(host) = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
    {
        if !state
            .allowed_hosts
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(host))
        {
            return Some(forbidden("audit endpoint host not allowed"));
        }
    }
    if let Some(origin) = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok())
    {
        if !state
            .allowed_origins
            .iter()
            .any(|allowed| allowed == origin)
        {
            return Some(forbidden("audit endpoint origin not allowed"));
        }
    }
    None
}

fn forbidden(message: &str) -> Response {
    (
        StatusCode::FORBIDDEN,
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({"error": message})),
    )
        .into_response()
}

// ---------------------------------------------------------------------------
// Client half
// ---------------------------------------------------------------------------

/// One successful fetch: the snapshot plus the server's `ETag`, used by the
/// poller to skip re-applying (and to slow down) unchanged snapshots.
#[derive(Debug, Clone)]
pub struct Fetched {
    pub snapshot: Snapshot,
    pub etag: Option<String>,
}

/// One bounded loopback GET of `/monitor/snapshot`. HTTP/1.0 with
/// `Connection: close` keeps framing trivial (no chunked responses) and is
/// all an attach probe needs.
pub async fn fetch_snapshot(target: SocketAddr) -> Result<Snapshot, FetchError> {
    fetch_snapshot_etag(target, None)
        .await
        .map(|fetched| fetched.snapshot)
}

pub async fn fetch_snapshot_etag(
    target: SocketAddr,
    etag: Option<&str>,
) -> Result<Fetched, FetchError> {
    if !target.ip().is_loopback() {
        return Err(FetchError::NotLoopback(target));
    }
    tokio::time::timeout(FETCH_TIMEOUT, fetch_snapshot_inner(target, etag))
        .await
        .map_err(|_| FetchError::Timeout(target))?
}

async fn fetch_snapshot_inner(
    target: SocketAddr,
    etag: Option<&str>,
) -> Result<Fetched, FetchError> {
    let mut stream = TcpStream::connect(target)
        .await
        .map_err(|error| FetchError::Connect(target, error.to_string()))?;
    let _ = stream.set_nodelay(true);
    let mut request = format!(
        "GET {SNAPSHOT_PATH} HTTP/1.0\r\nHost: {target}\r\nAccept: application/json\r\n\
         Connection: close\r\nUser-Agent: {SERVER_NAME}-attach/{version}\r\n",
        version = env!("CARGO_PKG_VERSION")
    );
    if let Some(etag) = etag {
        request.push_str(&format!("If-None-Match: {etag}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|error| FetchError::Transport(target, error.to_string()))?;
    let mut bytes = Vec::with_capacity(16 * 1024);
    let mut chunk = [0_u8; 16 * 1024];
    loop {
        let read = stream
            .read(&mut chunk)
            .await
            .map_err(|error| FetchError::Transport(target, error.to_string()))?;
        if read == 0 {
            break;
        }
        if bytes.len().saturating_add(read) > MAX_SNAPSHOT_BYTES {
            return Err(FetchError::Transport(
                target,
                format!("snapshot exceeds {MAX_SNAPSHOT_BYTES} byte bound"),
            ));
        }
        bytes.extend_from_slice(&chunk[..read]);
    }
    parse_response(target, &bytes)
}

fn parse_response(target: SocketAddr, bytes: &[u8]) -> Result<Fetched, FetchError> {
    let Some(header_end) = find_subslice(bytes, b"\r\n\r\n") else {
        return Err(FetchError::Transport(
            target,
            "response has no header block".into(),
        ));
    };
    let head = std::str::from_utf8(&bytes[..header_end])
        .map_err(|error| FetchError::Transport(target, error.to_string()))?;
    let mut header_lines = head.split("\r\n");
    let status_line = header_lines
        .next()
        .unwrap_or_default()
        .split_ascii_whitespace()
        .collect::<Vec<_>>();
    let code = match (status_line.first(), status_line.get(1)) {
        (Some(protocol), Some(code)) if protocol.starts_with("HTTP/1.") => code
            .parse::<u16>()
            .map_err(|_| FetchError::Transport(target, "malformed status line".into()))?,
        _ => {
            return Err(FetchError::Transport(
                target,
                "malformed status line".into(),
            ));
        }
    };
    let mut etag = None;
    for line in header_lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("etag") {
                etag = Some(value.trim().to_owned());
            }
        }
    }
    let body = &bytes[header_end + 4..];
    if code != StatusCode::OK.as_u16() {
        // The body belongs to whatever answered on the port; it is rendered
        // in notices and stderr, so strip terminal controls and cut on a
        // character boundary (from_utf8_lossy repairs any split sequence).
        let detail = clean_text(
            String::from_utf8_lossy(&body[..body.len().min(256)]).trim(),
            AUDIT_TEXT_BYTES,
        );
        return Err(FetchError::Status(target, code, detail));
    }
    let snapshot: Snapshot = serde_json::from_slice(body)
        .map_err(|error| FetchError::Decode(target, error.to_string()))?;
    if snapshot.server != SERVER_NAME {
        return Err(FetchError::NotMonitor(target));
    }
    if snapshot.events.len() > MAX_POLLED_EVENTS {
        return Err(FetchError::Decode(
            target,
            format!("snapshot carries {} events", snapshot.events.len()),
        ));
    }
    Ok(Fetched { snapshot, etag })
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// A snapshot is only ever rendered, so hostile strings are cleaned and
/// bounded again on arrival even though the trusted server already did.
/// Payload fields go through the store's JSON-level sanitizer so controls
/// smuggled in as `\u`-escapes (C1/DEL are controls to Rust but plain text
/// inside a JSON document) are stripped after decoding, not just before.
fn clean_event(mut event: Event) -> Event {
    event.invocation_id = clean_text(&event.invocation_id, AUDIT_TEXT_BYTES);
    event.connection_id = clean_text(&event.connection_id, AUDIT_TEXT_BYTES);
    event.request_id = clean_text(&event.request_id, AUDIT_TEXT_BYTES);
    event.method = clean_text(&event.method, AUDIT_TEXT_BYTES);
    event.tool = event
        .tool
        .take()
        .map(|tool| clean_text(&tool, AUDIT_TEXT_BYTES));
    event.status = clean_text(&event.status, AUDIT_TEXT_BYTES);
    event.arguments = safe_payload(&event.arguments);
    event.result = safe_payload(&event.result);
    event
}

// ---------------------------------------------------------------------------
// Attached monitor state
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct RemoteState {
    events: Vec<Arc<Event>>,
    stats: MonitorStats,
    healthy: bool,
    error: Option<String>,
    instance: String,
}

/// Latest observed snapshot plus stream health, shared between the poller
/// task and the blocking TUI draw loop.
#[derive(Debug)]
pub struct RemoteMonitor {
    state: Mutex<RemoteState>,
}

#[derive(Debug, Clone)]
pub struct RemoteSnapshot {
    pub events: Vec<Arc<Event>>,
    pub stats: MonitorStats,
    pub healthy: bool,
    pub error: Option<String>,
    pub instance: String,
}

impl Default for RemoteMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl RemoteMonitor {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(RemoteState {
                events: Vec::new(),
                stats: MonitorStats::default(),
                healthy: false,
                error: None,
                instance: String::new(),
            }),
        }
    }

    pub fn update(&self, snapshot: Snapshot) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        // Reuse the previous Arc for unchanged events so identity-keyed TUI
        // caches (details pane) survive polling.
        let previous: HashMap<String, Arc<Event>> = state
            .events
            .iter()
            .cloned()
            .map(|event| (event.invocation_id.clone(), event))
            .collect();
        let mut events: Vec<Arc<Event>> = snapshot
            .events
            .into_iter()
            .map(clean_event)
            .map(|event| match previous.get(&event.invocation_id) {
                Some(retained) if **retained == event => retained.clone(),
                _ => Arc::new(event),
            })
            .collect();
        // Keep the newest end: an oversized (version-skewed) snapshot must
        // never freeze the live view on the oldest events.
        let excess = events.len().saturating_sub(MAX_EVENTS);
        events.drain(..excess);
        state.events = events;
        state.stats = snapshot.stats;
        state.healthy = true;
        state.error = None;
        state.instance = snapshot.instance;
    }

    /// Mark the stream healthy again without replacing the retained events
    /// (used when a poll confirmed nothing changed).
    pub fn mark_healthy(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.healthy = true;
        state.error = None;
    }

    pub fn mark_unhealthy(&self, error: String) {
        // Rendered in TUI notices; never trust foreign error bodies.
        let cleaned = clean_text(&error, AUDIT_TEXT_BYTES);
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.healthy = false;
        state.error = Some(cleaned);
    }

    pub fn snapshot(&self) -> RemoteSnapshot {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        RemoteSnapshot {
            events: state.events.clone(),
            stats: state.stats,
            healthy: state.healthy,
            error: state.error.clone(),
            instance: state.instance.clone(),
        }
    }
}

/// Poll `target` forever until cancelled, refreshing `remote`. The interval
/// backs off while the stream is unhealthy or idle (unchanged `ETag`) and
/// snaps back as soon as something changes.
pub fn spawn_poller(
    remote: Arc<RemoteMonitor>,
    target: SocketAddr,
    cancellation: CancellationToken,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut delay = POLL_INTERVAL;
        let mut etag: Option<String> = None;
        loop {
            match fetch_snapshot_etag(target, etag.as_deref()).await {
                Ok(fetched) => {
                    let changed = fetched.etag.as_deref() != etag.as_deref();
                    if changed {
                        remote.update(fetched.snapshot);
                        delay = POLL_INTERVAL;
                    } else {
                        remote.mark_healthy();
                        delay = (delay * 2).min(MAX_POLL_INTERVAL);
                    }
                    etag = fetched.etag;
                }
                Err(error) => {
                    remote.mark_unhealthy(error.to_string());
                    etag = None;
                    delay = (delay * 2).min(MAX_POLL_INTERVAL);
                }
            }
            tokio::select! {
                _ = cancellation.cancelled() => break,
                _ = tokio::time::sleep(delay) => {}
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitor::{Event, MAX_EVENT_COPY, now_ms};
    use serde_json::json;

    fn sample_event(id: &str, status: &str) -> Event {
        Event {
            invocation_id: id.into(),
            connection_id: "conn".into(),
            request_id: "7".into(),
            method: "tools/call".into(),
            tool: Some("Echo".into()),
            started_ms: now_ms().saturating_sub(50),
            ended_ms: if status == "started" { 0 } else { 100 },
            status: status.into(),
            argument_bytes: 4,
            result_bytes: 4,
            arguments: "{\"value\":8}".into(),
            result: "{\"ok\":true}".into(),
        }
    }

    fn snapshot(events: Vec<Event>, instance: &str) -> Snapshot {
        let count = events.len();
        Snapshot {
            server: SERVER_NAME.into(),
            version: "test".into(),
            instance: instance.into(),
            events,
            stats: MonitorStats {
                events: count,
                ..Default::default()
            },
        }
    }

    fn state(store: Arc<MonitorStore>) -> AuditState {
        AuditState::new(
            store,
            allowed_hosts("127.0.0.1:30007".parse().unwrap()),
            Vec::new(),
        )
    }

    fn header(name: &str, value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::HeaderName::from_bytes(name.as_bytes()).unwrap(),
            value.parse().unwrap(),
        );
        headers
    }

    #[test]
    fn snapshot_value_round_trips_through_the_event_shape() {
        let store = MonitorStore::new(None);
        store.record(sample_event("inv-1", "started"));
        store.record({
            let mut event = sample_event("inv-1", "ok");
            event.ended_ms = event.started_ms + 20;
            event
        });
        let value = snapshot_value(&store, "instance-1");
        assert_eq!(value["server"], SERVER_NAME);
        assert_eq!(value["instance"], "instance-1");
        assert_eq!(value["events"].as_array().unwrap().len(), 1);
        let decoded: Snapshot = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.server, SERVER_NAME);
        assert_eq!(decoded.instance, "instance-1");
        assert_eq!(decoded.events[0].status, "ok");
        assert_eq!(decoded.stats.events, 1);
    }

    #[test]
    fn guard_enforces_host_and_origin_like_the_mcp_route() {
        let store = MonitorStore::new(None);
        let audit = state(store.clone());
        assert!(
            guard(&audit, &HeaderMap::new()).is_none(),
            "local clients send neither header"
        );
        let mut allowed_origin = state(store.clone());
        allowed_origin.allowed_origins = vec!["http://localhost:5173".into()];
        assert!(guard(&allowed_origin, &header("origin", "http://localhost:5173")).is_none());
        for (name, value) in [
            ("host", "evil.example"),
            ("host", "127.0.0.1:9999"),
            ("origin", "https://example.invalid"),
        ] {
            let response = guard(&audit, &header(name, value)).expect(name);
            assert_eq!(response.status(), StatusCode::FORBIDDEN, "{name}: {value}");
        }
        // Loopback host spellings the listener actually answers on.
        for host in [
            "127.0.0.1",
            "127.0.0.1:30007",
            "localhost:30007",
            "LOCALHOST:30007",
        ] {
            assert!(guard(&audit, &header("host", host)).is_none(), "{host}");
        }
        // IPv6 loopback keeps its bracketed port form, which the attach client sends.
        let mut v6 = state(store.clone());
        v6.allowed_hosts = allowed_hosts("[::1]:30007".parse().unwrap());
        for host in ["[::1]:30007", "localhost:30007"] {
            assert!(guard(&v6, &header("host", host)).is_none(), "{host}");
        }
        assert!(guard(&v6, &header("host", "[::1]:9999")).is_some());
    }

    #[test]
    fn parse_response_classifies_status_not_monitor_and_bounds() {
        let target: SocketAddr = "127.0.0.1:30007".parse().unwrap();
        let ok = format!(
            "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nContent-Length: 2\r\n\r\n{}",
            json!({"server": SERVER_NAME, "version": "0.1.0", "instance": "i", "events": [], "stats": MonitorStats::default()})
        );
        let fetched = parse_response(target, ok.as_bytes()).unwrap();
        assert!(fetched.snapshot.events.is_empty());
        assert_eq!(fetched.etag.as_deref(), Some("\"v1\""));

        let missing = b"HTTP/1.1 404 Not Found\r\n\r\nnot found";
        assert!(matches!(
            parse_response(target, missing),
            Err(FetchError::Status(_, 404, _))
        ));
        let foreign = format!(
            "HTTP/1.0 200 OK\r\n\r\n{}",
            json!({"server": "other", "version": "1", "events": [], "stats": MonitorStats::default()})
        );
        assert!(matches!(
            parse_response(target, foreign.as_bytes()),
            Err(FetchError::NotMonitor(_))
        ));
        assert!(matches!(
            parse_response(target, b"garbage"),
            Err(FetchError::Transport(..))
        ));
        let truncated = format!(
            "HTTP/1.1 200 OK\r\n\r\n{}",
            json!({"server": SERVER_NAME, "version": "1", "events": [], "stats": {}})
        );
        assert!(matches!(
            parse_response(target, truncated.as_bytes()),
            Err(FetchError::Decode(..))
        ));
    }

    #[test]
    fn non_200_detail_is_sanitized_and_split_utf8_is_repaired() {
        let target: SocketAddr = "127.0.0.1:30007".parse().unwrap();
        let hostile = b"HTTP/1.1 500 X\r\n\r\n\x1b]52;c;clipboard\x07tail\xc3\xa9\xe2\x82";
        let Err(FetchError::Status(_, 500, detail)) = parse_response(target, hostile) else {
            panic!("expected status error");
        };
        assert!(!detail.contains('\u{1b}'), "{detail:?}");
        assert!(!detail.contains('\u{7}'), "{detail:?}");
        assert!(detail.contains("tail"), "{detail:?}");
        // The truncated trailing sequence is repaired, not dropped wholesale.
        assert!(detail.contains('\u{fffd}'), "{detail:?}");
    }

    #[test]
    fn clean_event_strips_controls_and_escapes_inside_payload_json() {
        let mut hostile = sample_event("inv-1", "ok");
        hostile.invocation_id = "\u{1b}]0;pwn\u{7}".into();
        hostile.arguments = r#"{"x":"\u009b2J\u009b31m"}"#.into();
        let cleaned = clean_event(hostile);
        assert_eq!(cleaned.invocation_id, "]0;pwn");
        assert_eq!(cleaned.arguments, r#"{"x":"2J31m"}"#);
        assert!(serde_json::from_str::<Value>(&cleaned.arguments).is_ok());

        let mut huge = sample_event("inv-1", "ok");
        huge.arguments = serde_json::json!({"text": "x".repeat(MAX_EVENT_COPY + 1024)}).to_string();
        let cleaned = clean_event(huge);
        assert!(
            cleaned.arguments.len() <= MAX_EVENT_COPY,
            "{}",
            cleaned.arguments.len()
        );
        assert!(
            serde_json::from_str::<Value>(&cleaned.arguments).is_ok(),
            "bounded payload must stay valid JSON: {}",
            cleaned.arguments
        );
    }

    #[test]
    fn remote_monitor_reuses_arc_identity_and_keeps_the_newest_tail() {
        let remote = RemoteMonitor::new();
        // One event value reused verbatim: `now_ms()` could tick between two
        // fresh samples and make the "unchanged" poll legitimately different.
        let event = sample_event("inv-1", "started");
        remote.update(snapshot(vec![event.clone()], "i-1"));
        let first = remote.snapshot().events[0].clone();
        remote.update(snapshot(vec![event], "i-1"));
        assert!(
            Arc::ptr_eq(&first, &remote.snapshot().events[0]),
            "unchanged events must keep their Arc identity for TUI caches"
        );
        remote.update(snapshot(vec![sample_event("inv-1", "ok")], "i-1"));
        assert!(!Arc::ptr_eq(&first, &remote.snapshot().events[0]));
        assert_eq!(remote.snapshot().instance, "i-1");

        // A version-skewed oversized snapshot keeps the newest events.
        let events: Vec<Event> = (0..MAX_EVENTS + 2)
            .map(|index| sample_event(&format!("inv-{index}"), "ok"))
            .collect();
        let newest = events.last().unwrap().invocation_id.clone();
        remote.update(snapshot(events, "i-1"));
        let observed = remote.snapshot();
        assert_eq!(observed.events.len(), MAX_EVENTS);
        assert_eq!(observed.events.last().unwrap().invocation_id, newest);
    }

    #[test]
    fn mark_unhealthy_strips_terminal_controls_from_foreign_errors() {
        let remote = RemoteMonitor::new();
        remote.update(snapshot(Vec::new(), "i-1"));
        remote.mark_unhealthy("lost (\u{1b}]0;pwn\u{7})".into());
        let error = remote.snapshot().error.unwrap();
        assert!(!error.contains('\u{1b}'), "{error:?}");
        assert!(error.contains("lost"), "{error:?}");
    }

    #[tokio::test]
    async fn attach_client_round_trips_a_live_audit_router_and_tracks_health() {
        let store = MonitorStore::new(None);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let audit = AuditState::new(store.clone(), allowed_hosts(address), Vec::new());
        let server = tokio::spawn(async move {
            axum::serve(listener, audit_router(audit)).await.unwrap();
        });

        let fetched = fetch_snapshot_etag(address, None).await.unwrap();
        assert!(fetched.snapshot.events.is_empty());
        assert!(!fetched.snapshot.instance.is_empty());
        assert!(fetched.etag.is_some());

        store.record(sample_event("inv-1", "started"));
        let fetched = fetch_snapshot_etag(address, None).await.unwrap();
        assert_eq!(fetched.snapshot.events.len(), 1);
        assert_eq!(fetched.snapshot.events[0].tool.as_deref(), Some("Echo"));

        let remote = Arc::new(RemoteMonitor::new());
        let cancellation = CancellationToken::new();
        let poller = spawn_poller(remote.clone(), address, cancellation.clone());
        let deadline = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let observed = remote.snapshot();
                if observed.healthy && observed.events.len() == 1 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(deadline.is_ok(), "poller never observed the recorded event");

        server.abort();
        let _ = server.await;
        let deadline = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if !remote.snapshot().healthy {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(deadline.is_ok(), "poller never noticed the dead server");
        assert!(remote.snapshot().error.is_some());
        cancellation.cancel();
        let _ = tokio::time::timeout(Duration::from_secs(1), poller).await;
    }

    #[tokio::test]
    async fn attach_client_rejects_off_loopback_targets() {
        let target: SocketAddr = "192.0.2.10:30007".parse().unwrap();
        assert!(matches!(
            fetch_snapshot(target).await,
            Err(FetchError::NotLoopback(_))
        ));
    }
}

//! Bounded, lossy observation of the shared dispatcher. Persistence contains metadata only.

use std::{
    collections::VecDeque,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc};

pub const MAX_EVENTS: usize = 2000;
pub const MAX_EVENT_COPY: usize = 64 * 1024;
pub const MAX_MONITOR_BYTES: usize = 64 * 1024 * 1024;
// Reserve room for a frozen UI snapshot, one completion per retained call, and rendering.
// Shared Arc snapshots normally cost only their pointer vectors.
const STORE_BYTES: usize = MAX_MONITOR_BYTES / 3;
const METADATA_BYTES: usize = 512;
const CHANNEL_CAPACITY: usize = 128;
const LOG_BYTES: u64 = 10 * 1024 * 1024;
const LOG_FILES: usize = 5; // current file plus .1 through .4

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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

impl Event {
    pub fn is_active(&self) -> bool {
        self.ended_ms == 0 && matches!(self.status.as_str(), "started" | "inflight")
    }

    pub fn elapsed_ms(&self, now: u128) -> u128 {
        if self.is_active() { now } else { self.ended_ms }.saturating_sub(self.started_ms)
    }

    fn retained_bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.invocation_id.len()
            + self.connection_id.len()
            + self.request_id.len()
            + self.method.len()
            + self.tool.as_deref().map_or(0, str::len)
            + self.status.len()
            + self.arguments.len()
            + self.result.len()
    }

    fn metadata(&self) -> Self {
        let mut event = self.clone();
        event.arguments.clear();
        event.result.clear();
        event.arguments.shrink_to_fit();
        event.result.shrink_to_fit();
        event
    }
}

#[derive(Debug, Clone)]
pub enum CoreEvent {
    /// Broadcasts intentionally omit payload copies; read a snapshot for details.
    Invocation(Event),
    CatalogChanged(String),
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct MonitorStats {
    pub events: usize,
    pub active: usize,
    pub retained_bytes: usize,
    pub observed: u64,
    pub evicted: u64,
    pub dropped: u64,
    pub lagged: u64,
    pub jsonl_dropped: u64,
    pub jsonl_errors: u64,
}

#[derive(Debug, Default)]
struct Counters {
    observed: AtomicU64,
    evicted: AtomicU64,
    dropped: AtomicU64,
    lagged: AtomicU64,
    jsonl_dropped: AtomicU64,
    jsonl_errors: AtomicU64,
}

#[derive(Debug, Default)]
struct Ring {
    events: VecDeque<Arc<Event>>,
    bytes: usize,
}

#[derive(Debug)]
pub struct MonitorStore {
    events: Mutex<Ring>,
    sequence: AtomicU64,
    events_tx: broadcast::Sender<CoreEvent>,
    jsonl_tx: Mutex<Option<mpsc::Sender<Event>>>,
    writer: Mutex<Option<tokio::task::JoinHandle<()>>>,
    counters: Arc<Counters>,
}

impl MonitorStore {
    pub fn new(jsonl_path: Option<PathBuf>) -> Arc<Self> {
        let (events_tx, _) = broadcast::channel(CHANNEL_CAPACITY);
        let counters = Arc::new(Counters::default());
        let mut writer = None;
        let jsonl_tx = jsonl_path.and_then(|path| {
            let Ok(runtime) = tokio::runtime::Handle::try_current() else {
                counters.jsonl_errors.fetch_add(1, Ordering::Relaxed);
                return None;
            };
            let (tx, mut rx) = mpsc::channel::<Event>(CHANNEL_CAPACITY);
            let counts = counters.clone();
            // File IO runs on the blocking pool. The dispatcher only ever uses try_send.
            writer = Some(runtime.spawn_blocking(move || {
                let mut log = MetadataLog::new(path, LOG_BYTES);
                while let Some(event) = rx.blocking_recv() {
                    if let Err(error) = log.append(&event) {
                        counts.jsonl_errors.fetch_add(1, Ordering::Relaxed);
                        tracing::warn!(%error, "monitor metadata JSONL write failed");
                    }
                }
            }));
            Some(tx)
        });
        Arc::new(Self {
            events: Mutex::new(Ring::default()),
            sequence: AtomicU64::new(1),
            events_tx,
            jsonl_tx: Mutex::new(jsonl_tx),
            writer: Mutex::new(writer),
            counters,
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<CoreEvent> {
        self.events_tx.subscribe()
    }

    pub fn snapshot(&self) -> Vec<Event> {
        self.snapshot_shared()
            .iter()
            .map(|event| (**event).clone())
            .collect()
    }

    pub fn snapshot_shared(&self) -> Vec<Arc<Event>> {
        self.events
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .events
            .iter()
            .cloned()
            .collect()
    }

    pub fn stats(&self) -> MonitorStats {
        let ring = self.events.lock().unwrap_or_else(|e| e.into_inner());
        MonitorStats {
            events: ring.events.len(),
            active: ring.events.iter().filter(|e| e.is_active()).count(),
            retained_bytes: ring.bytes,
            observed: self.counters.observed.load(Ordering::Relaxed),
            evicted: self.counters.evicted.load(Ordering::Relaxed),
            dropped: self.counters.dropped.load(Ordering::Relaxed),
            lagged: self.counters.lagged.load(Ordering::Relaxed),
            jsonl_dropped: self.counters.jsonl_dropped.load(Ordering::Relaxed),
            jsonl_errors: self.counters.jsonl_errors.load(Ordering::Relaxed),
        }
    }

    pub fn note_lagged(&self, count: u64) {
        self.counters.lagged.fetch_add(count, Ordering::Relaxed);
    }

    pub fn next_id(&self) -> String {
        format!("inv-{}", self.sequence.fetch_add(1, Ordering::Relaxed))
    }

    /// Insert or update an invocation without waiting for a reader, logger, or subscriber.
    pub fn record(&self, mut event: Event) {
        event.invocation_id = clean_text(&event.invocation_id, METADATA_BYTES);
        event.connection_id = clean_text(&event.connection_id, METADATA_BYTES);
        event.request_id = clean_text(&event.request_id, METADATA_BYTES);
        event.method = clean_text(&event.method, METADATA_BYTES);
        event.tool = event.tool.map(|tool| clean_text(&tool, METADATA_BYTES));
        event.status = clean_text(&event.status, METADATA_BYTES);
        event.arguments = safe_payload(&event.arguments);
        event.result = safe_payload(&event.result);
        self.counters.observed.fetch_add(1, Ordering::Relaxed);
        let metadata = event.metadata();
        match self.events.try_lock() {
            Ok(mut ring) => {
                let index = ring
                    .events
                    .iter()
                    .position(|old| old.invocation_id == event.invocation_id);
                if let Some(index) = index {
                    let previous = ring.events.remove(index).expect("known event index");
                    ring.bytes = ring.bytes.saturating_sub(previous.retained_bytes());
                    ring.bytes += event.retained_bytes();
                    ring.events.insert(index, Arc::new(event));
                } else {
                    ring.bytes += event.retained_bytes();
                    ring.events.push_back(Arc::new(event));
                }
                while ring.events.len() > MAX_EVENTS || ring.bytes > STORE_BYTES {
                    // Prefer complete history, but even an all-active stream has a hard bound.
                    let index = ring.events.iter().position(|e| !e.is_active()).unwrap_or(0);
                    if let Some(old) = ring.events.remove(index) {
                        ring.bytes = ring.bytes.saturating_sub(old.retained_bytes());
                        self.counters.evicted.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            Err(_) => {
                self.counters.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
        if let Ok(tx) = self.jsonl_tx.try_lock() {
            if let Some(tx) = tx.as_ref() {
                if tx.try_send(metadata.clone()).is_err() {
                    self.counters.jsonl_dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
        } else {
            self.counters.jsonl_dropped.fetch_add(1, Ordering::Relaxed);
        }
        let _ = self.events_tx.send(CoreEvent::Invocation(metadata));
    }

    pub fn catalog_changed(&self, revision: String) {
        let _ = self.events_tx.send(CoreEvent::CatalogChanged(clean_text(
            &revision,
            METADATA_BYTES,
        )));
    }

    /// Stop accepting metadata and give the bounded queue a bounded chance to drain.
    pub async fn shutdown(&self, grace: Duration) {
        self.jsonl_tx
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        let writer = self.writer.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(mut writer) = writer {
            if tokio::time::timeout(grace, &mut writer).await.is_err() {
                writer.abort();
                self.counters.jsonl_dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

pub fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn utf8_prefix(value: &str, max: usize) -> &str {
    let mut end = value.len().min(max);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

pub fn bounded(value: &str) -> String {
    utf8_prefix(value, MAX_EVENT_COPY).into()
}

/// Plain text for terminal display: discard controls, escape sequences, and bidi controls.
pub fn clean_text(value: &str, max: usize) -> String {
    let mut output = String::new();
    for ch in value.chars() {
        if ch.is_control() || matches!(ch, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}') {
            continue;
        }
        if output.len() + ch.len_utf8() > max {
            break;
        }
        output.push(ch);
    }
    output
}

fn secret_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    [
        "token",
        "password",
        "passwd",
        "secret",
        "authorization",
        "apikey",
        "accesskey",
        "privatekey",
        "cookie",
        "credential",
    ]
    .iter()
    .any(|needle| normalized.contains(needle))
}

pub fn sanitize_value(value: &Value) -> Value {
    fn visit(value: &Value, remaining: &mut usize, depth: usize) -> Value {
        if *remaining == 0 || depth > 24 {
            return Value::String("[truncated]".into());
        }
        *remaining = remaining.saturating_sub(8);
        match value {
            Value::Object(map) => {
                let mut safe = serde_json::Map::new();
                for (key, value) in map {
                    if *remaining < 32 {
                        safe.insert("_truncated".into(), Value::Bool(true));
                        break;
                    }
                    let safe_key = clean_text(key, (*remaining).min(METADATA_BYTES));
                    *remaining = remaining.saturating_sub(safe_key.len());
                    safe.insert(
                        safe_key,
                        if secret_key(key) {
                            Value::String("[redacted]".into())
                        } else {
                            visit(value, remaining, depth + 1)
                        },
                    );
                }
                Value::Object(safe)
            }
            Value::Array(values) => {
                let mut safe = Vec::new();
                for value in values {
                    if *remaining < 32 {
                        safe.push(Value::String("[truncated]".into()));
                        break;
                    }
                    safe.push(visit(value, remaining, depth + 1));
                }
                Value::Array(safe)
            }
            Value::String(value) => {
                let text = clean_text(value, *remaining);
                *remaining = remaining.saturating_sub(text.len());
                Value::String(text)
            }
            other => other.clone(),
        }
    }
    visit(value, &mut (MAX_EVENT_COPY / 2), 0)
}

pub fn bounded_json(value: &Value) -> String {
    let safe = sanitize_value(value);
    let encoded = serde_json::to_string(&safe).unwrap_or_else(|_| "null".into());
    if encoded.len() <= MAX_EVENT_COPY {
        return encoded;
    }
    // Escaping can expand text sixfold. Keep a valid JSON envelope even in that case.
    serde_json::to_string(
        &json!({"truncated":true,"preview":utf8_prefix(&encoded, MAX_EVENT_COPY / 8)}),
    )
    .unwrap_or_else(|_| "null".into())
}

fn safe_payload(payload: &str) -> String {
    if payload.is_empty() {
        return String::new();
    }
    if payload.len() > MAX_EVENT_COPY {
        return "{\"omitted\":\"payload exceeded 64 KiB\"}".into();
    }
    match serde_json::from_str::<Value>(payload) {
        Ok(value) => bounded_json(&value),
        Err(_) => "{\"omitted\":\"invalid or truncated JSON\"}".into(),
    }
}

#[derive(Serialize)]
struct EventMetadata<'a> {
    invocation_id: &'a str,
    connection_id: &'a str,
    request_id: &'a str,
    method: &'a str,
    tool: &'a Option<String>,
    started_ms: u128,
    ended_ms: u128,
    status: &'a str,
    argument_bytes: usize,
    result_bytes: usize,
}

struct MetadataLog {
    path: PathBuf,
    max_bytes: u64,
}

impl MetadataLog {
    fn new(path: PathBuf, max_bytes: u64) -> Self {
        Self { path, max_bytes }
    }

    fn append(&mut self, event: &Event) -> io::Result<()> {
        let mut line = serde_json::to_vec(&EventMetadata {
            invocation_id: &event.invocation_id,
            connection_id: &event.connection_id,
            request_id: &event.request_id,
            method: &event.method,
            tool: &event.tool,
            started_ms: event.started_ms,
            ended_ms: event.ended_ms,
            status: &event.status,
            argument_bytes: event.argument_bytes,
            result_bytes: event.result_bytes,
        })?;
        line.push(b'\n');
        if self.path.exists() {
            let metadata = std::fs::symlink_metadata(&self.path)?;
            if !metadata.file_type().is_file() {
                return Err(io::Error::other("metadata log must be a regular file"));
            }
            if metadata.len().saturating_add(line.len() as u64) > self.max_bytes {
                self.rotate()?;
            }
        }
        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(&self.path)?.write_all(&line)
    }

    fn rotate(&self) -> io::Result<()> {
        let oldest = suffix(&self.path, LOG_FILES - 1);
        match std::fs::remove_file(oldest) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        for index in (1..LOG_FILES - 1).rev() {
            let from = suffix(&self.path, index);
            if from.exists() {
                std::fs::rename(from, suffix(&self.path, index + 1))?;
            }
        }
        std::fs::rename(&self.path, suffix(&self.path, 1))
    }
}

fn suffix(path: &Path, index: usize) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(format!(".{index}"));
    name.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn sample(id: &str) -> Event {
        Event {
            invocation_id: id.into(),
            connection_id: "conn".into(),
            request_id: "1".into(),
            method: "tools/call".into(),
            tool: Some("Echo".into()),
            started_ms: 10,
            ended_ms: 0,
            status: "started".into(),
            argument_bytes: 2,
            result_bytes: 0,
            arguments: "{}".into(),
            result: String::new(),
        }
    }

    #[test]
    fn completion_updates_in_place_and_shared_snapshots_stay_frozen() {
        let store = MonitorStore::new(None);
        store.record(sample("a"));
        store.record(sample("b"));
        let frozen = store.snapshot_shared();
        let mut complete = sample("a");
        complete.ended_ms = 20;
        complete.status = "ok".into();
        complete.result = "{\"done\":true}".into();
        store.record(complete);
        assert_eq!(store.stats().events, 2);
        assert_eq!(store.stats().active, 1);
        assert!(frozen[0].is_active());
        assert_eq!(store.snapshot()[0].status, "ok");
        assert_eq!(store.snapshot()[1].invocation_id, "b");
    }

    #[test]
    fn event_count_bytes_and_payload_sizes_are_bounded() {
        let store = MonitorStore::new(None);
        for index in 0..MAX_EVENTS + 40 {
            let mut event = sample(&index.to_string());
            event.status = "ok".into();
            event.ended_ms = 20;
            store.record(event);
        }
        assert_eq!(store.stats().events, MAX_EVENTS);
        assert_eq!(store.stats().evicted, 40);
        let large = bounded_json(&json!({"text":"☃".repeat(90_000)}));
        assert!(large.len() <= MAX_EVENT_COPY);
        assert!(serde_json::from_str::<Value>(&large).is_ok());
        for index in 0..1100 {
            let mut event = sample(&index.to_string());
            event.arguments = large.clone();
            event.result = large.clone();
            store.record(event);
        }
        assert!(store.stats().retained_bytes <= STORE_BYTES);
        assert!(store.stats().retained_bytes < MAX_MONITOR_BYTES);
    }

    #[test]
    fn redaction_handles_aliases_nested_arrays_and_terminal_controls() {
        let safe = bounded_json(
            &json!({"Api-Key":"topsecret","nested":[{"PRIVATE_KEY":"sensitive","text":"\u{1b}[31mhello\u{202e}"}],"access_token":"secret"}),
        );
        assert!(!safe.contains("topsecret"));
        assert!(!safe.contains("sensitive"));
        assert!(!safe.contains("\\u001b"));
        assert!(safe.contains("[redacted]"));
        let store = MonitorStore::new(None);
        let mut event = sample("a");
        event.arguments = "{\"password\":\"raw".into();
        store.record(event);
        assert!(!store.snapshot()[0].arguments.contains("raw"));
    }

    #[tokio::test]
    async fn contention_and_subscriber_lag_are_observable() {
        let store = MonitorStore::new(None);
        let guard = store.events.lock().unwrap();
        store.record(sample("lost"));
        drop(guard);
        assert_eq!(store.stats().dropped, 1);
        let mut rx = store.subscribe();
        for index in 0..300 {
            store.record(sample(&index.to_string()));
        }
        let Err(broadcast::error::RecvError::Lagged(count)) = rx.recv().await else {
            panic!("expected lag")
        };
        store.note_lagged(count);
        assert!(store.stats().lagged > 0);
    }

    #[test]
    fn metadata_log_rotates_five_files_and_never_contains_payloads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("events.jsonl");
        let mut log = MetadataLog::new(path.clone(), 500);
        for index in 0..40 {
            let mut event = sample(&index.to_string());
            event.arguments = "payload-secret".into();
            event.result = "result-secret".into();
            log.append(&event).unwrap();
        }
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), LOG_FILES);
        for index in 0..LOG_FILES {
            let file = if index == 0 {
                path.clone()
            } else {
                suffix(&path, index)
            };
            let text = std::fs::read_to_string(file).unwrap();
            assert!(!text.contains("payload-secret"));
            assert!(!text.contains("result-secret"));
            for line in text.lines() {
                let value: Value = serde_json::from_str(line).unwrap();
                assert!(value.get("arguments").is_none());
                assert!(value.get("result").is_none());
            }
        }
    }

    #[tokio::test]
    async fn metadata_writer_reports_errors_and_drains_on_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("events.jsonl");
        let store = MonitorStore::new(Some(path.clone()));
        store.record(sample("a"));
        store.shutdown(Duration::from_secs(2)).await;
        assert!(
            std::fs::read_to_string(path)
                .unwrap()
                .contains("invocation_id")
        );
        let invalid = MonitorStore::new(Some(dir.path().to_path_buf()));
        invalid.record(sample("bad"));
        invalid.shutdown(Duration::from_secs(2)).await;
        assert_eq!(invalid.stats().jsonl_errors, 1);
    }
}

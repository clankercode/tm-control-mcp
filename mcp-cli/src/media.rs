//! MCP media resources backed by the native tm-control-mcp bridge.
//!
//! This module deliberately does not own the native `TakeScreenshot` call. The
//! core dispatcher calls [`MediaService::prepare`] immediately before its
//! native call and [`MediaService::finish`] with the successful response. The
//! permit returned by `prepare` is held across that call, so two captures can
//! never race the before/after directory snapshots.

use std::{
    collections::{BTreeMap, VecDeque},
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use rmcp::model::{ContentBlock, Resource, ResourceContents};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use uuid::Uuid;

use crate::{NativeBackend, NativeCatalog, NativeExpect, NativeResponse};

pub const GUIDE_URI_PREFIX: &str = "tm-control://guide/";
pub const SCREENSHOT_URI_PREFIX: &str = "tm-control://screenshot/";

const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const DEFAULT_STABLE_FOR: Duration = Duration::from_millis(60);
const DEFAULT_MAX_SCAN_FILES: usize = 4096;
const DEFAULT_MAX_SCAN_BYTES: u64 = 64 * 1024 * 1024;
// Base64 adds 4/3 overhead; 8 MiB leaves headroom in the 16 MiB protocol frame.
const DEFAULT_MAX_IMAGE_BYTES: u64 = 8 * 1024 * 1024;
const DEFAULT_MAX_ARTIFACTS: usize = 8;
const DEFAULT_MAX_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;
const MAX_WAIT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_POLL_INTERVAL: Duration = Duration::from_secs(1);
const MAX_STABLE_FOR: Duration = Duration::from_secs(2);
const MAX_SCAN_FILES: usize = 32 * 1024;
const MAX_SCAN_BYTES: u64 = 512 * 1024 * 1024;
const MAX_IMAGE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_ARTIFACTS: usize = 128;
const MAX_ARTIFACT_BYTES: u64 = 128 * 1024 * 1024;
const MAX_GUIDE_TOPIC_BYTES: usize = 256;
const MAX_GUIDE_TITLE_BYTES: usize = 4096;
const MAX_GUIDE_BODY_BYTES: usize = 512 * 1024;

#[derive(Debug, Clone)]
pub struct ScreenshotConfig {
    /// Canonical, approved Trackmania user-game-folder root.
    pub root: PathBuf,
    pub wait_timeout: Duration,
    pub poll_interval: Duration,
    pub stable_for: Duration,
    pub max_scan_files: usize,
    pub max_scan_bytes: u64,
    pub max_image_bytes: u64,
    pub max_artifacts: usize,
    pub max_artifact_bytes: u64,
}

impl ScreenshotConfig {
    /// Build a configuration from an explicit root. The root must already
    /// exist so that all later reads stay within one canonical directory.
    pub fn new(root: impl Into<PathBuf>) -> Result<Self> {
        Self::with_limits(root.into(), Self::default_limits())
    }

    /// Resolve the configured mapping used by the CLI: explicit
    /// `TM_USER_GAME_FOLDER`, then a platform-appropriate Documents folder.
    pub fn from_environment() -> Result<Self> {
        let root = env::var_os("TM_USER_GAME_FOLDER")
            .map(PathBuf::from)
            .unwrap_or_else(default_trackmania_folder);
        Self::new(root)
    }

    pub fn default_limits() -> ScreenshotLimits {
        ScreenshotLimits {
            wait_timeout: DEFAULT_WAIT_TIMEOUT,
            poll_interval: DEFAULT_POLL_INTERVAL,
            stable_for: DEFAULT_STABLE_FOR,
            max_scan_files: DEFAULT_MAX_SCAN_FILES,
            max_scan_bytes: DEFAULT_MAX_SCAN_BYTES,
            max_image_bytes: DEFAULT_MAX_IMAGE_BYTES,
            max_artifacts: DEFAULT_MAX_ARTIFACTS,
            max_artifact_bytes: DEFAULT_MAX_ARTIFACT_BYTES,
        }
    }

    pub fn with_limits(root: PathBuf, limits: ScreenshotLimits) -> Result<Self> {
        let root = fs::canonicalize(&root)
            .with_context(|| format!("canonicalize screenshot root {}", root.display()))?;
        ensure!(
            root.is_dir(),
            "screenshot root is not a directory: {}",
            root.display()
        );
        ensure!(
            !limits.wait_timeout.is_zero(),
            "screenshot wait timeout must be non-zero"
        );
        ensure!(
            limits.wait_timeout <= MAX_WAIT_TIMEOUT,
            "screenshot wait timeout exceeds 30 seconds"
        );
        ensure!(
            !limits.poll_interval.is_zero(),
            "screenshot poll interval must be non-zero"
        );
        ensure!(
            limits.poll_interval <= MAX_POLL_INTERVAL,
            "screenshot poll interval exceeds 1 second"
        );
        ensure!(
            !limits.stable_for.is_zero(),
            "screenshot stability interval must be non-zero"
        );
        ensure!(
            limits.stable_for <= MAX_STABLE_FOR,
            "screenshot stability interval exceeds 2 seconds"
        );
        ensure!(
            limits.max_scan_files > 0 && limits.max_scan_files <= MAX_SCAN_FILES,
            "invalid screenshot file-count limit"
        );
        ensure!(
            limits.max_scan_bytes > 0 && limits.max_scan_bytes <= MAX_SCAN_BYTES,
            "invalid screenshot scan-byte limit"
        );
        ensure!(
            limits.max_image_bytes > 0 && limits.max_image_bytes <= MAX_IMAGE_BYTES,
            "invalid screenshot image-byte limit"
        );
        ensure!(
            limits.max_artifacts > 0 && limits.max_artifacts <= MAX_ARTIFACTS,
            "invalid screenshot artifact-count limit"
        );
        ensure!(
            limits.max_artifact_bytes > 0 && limits.max_artifact_bytes <= MAX_ARTIFACT_BYTES,
            "invalid screenshot artifact-byte limit"
        );
        Ok(Self {
            root,
            wait_timeout: limits.wait_timeout,
            poll_interval: limits.poll_interval,
            stable_for: limits.stable_for,
            max_scan_files: limits.max_scan_files,
            max_scan_bytes: limits.max_scan_bytes,
            max_image_bytes: limits.max_image_bytes,
            max_artifacts: limits.max_artifacts,
            max_artifact_bytes: limits.max_artifact_bytes,
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ScreenshotLimits {
    pub wait_timeout: Duration,
    pub poll_interval: Duration,
    pub stable_for: Duration,
    pub max_scan_files: usize,
    pub max_scan_bytes: u64,
    pub max_image_bytes: u64,
    pub max_artifacts: usize,
    pub max_artifact_bytes: u64,
}

fn default_trackmania_folder() -> PathBuf {
    #[cfg(windows)]
    {
        env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"))
            .join("Documents")
            .join("Trackmania")
    }
    #[cfg(not(windows))]
    {
        env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join(".local/share/Steam/steamapps/compatdata/2225070/pfx/drive_c/users/steamuser/Documents/Trackmania")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuideSummary {
    pub topic: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Guide {
    pub topic: String,
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuideResource {
    pub topic: String,
    pub title: String,
    pub uri: String,
}

impl GuideResource {
    pub fn to_resource(&self) -> Resource {
        Resource::new(self.uri.clone(), self.topic.clone())
            .with_title(self.title.clone())
            .with_mime_type("text/markdown")
            .with_description("Native tm-control-mcp guide")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageArtifact {
    uri: String,
    mime_type: &'static str,
    bytes: Arc<[u8]>,
}

impl ImageArtifact {
    pub fn uri(&self) -> &str {
        &self.uri
    }

    pub fn mime_type(&self) -> &'static str {
        self.mime_type
    }

    pub fn size_bytes(&self) -> usize {
        self.bytes.len()
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn image_block(&self) -> ContentBlock {
        ContentBlock::image(base64_encode(&self.bytes), self.mime_type)
    }

    pub fn resource(&self) -> Resource {
        Resource::new(self.uri.clone(), self.uri.clone())
            .with_mime_type(self.mime_type)
            .with_size(self.bytes.len() as u64)
            .with_description("Fresh immutable tm-control-mcp screenshot")
    }

    pub fn resource_contents(&self) -> ResourceContents {
        ResourceContents::blob(base64_encode(&self.bytes), self.uri.clone())
            .with_mime_type(self.mime_type)
    }
}

pub struct MediaService {
    backend: Arc<dyn NativeBackend>,
    screenshot: ScreenshotConfig,
    artifacts: Mutex<ArtifactStore>,
    capture_lock: Arc<AsyncMutex<()>>,
}

impl MediaService {
    pub fn new(backend: Arc<dyn NativeBackend>, screenshot: ScreenshotConfig) -> Arc<Self> {
        Arc::new(Self {
            backend,
            screenshot: screenshot.clone(),
            artifacts: Mutex::new(ArtifactStore::new(
                screenshot.max_artifacts,
                screenshot.max_artifact_bytes,
            )),
            capture_lock: Arc::new(AsyncMutex::new(())),
        })
    }

    pub fn from_environment(backend: Arc<dyn NativeBackend>) -> Result<Arc<Self>> {
        Ok(Self::new(backend, ScreenshotConfig::from_environment()?))
    }

    /// Enumerate only native guides. There is intentionally no static index or
    /// adapter-owned fallback guide: the native bridge is the source of truth.
    pub async fn list_guides(&self) -> Result<Vec<GuideSummary>> {
        let response = self.call_native("ListGuides", json!({})).await?;
        ensure_native_success("ListGuides", &response)?;
        let output = native_output(&response.data);
        let guides = output
            .get("guides")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow!("ListGuides output has no guides array"))?;
        guides.iter().map(parse_guide_summary).collect()
    }

    pub async fn get_guide(&self, topic: &str) -> Result<Guide> {
        validate_topic(topic)?;
        let response = self
            .call_native("GetGuide", json!({"topic": topic}))
            .await?;
        ensure_native_success("GetGuide", &response)?;
        let guide = parse_guide(native_output(&response.data))?;
        ensure!(guide.topic == topic, "GetGuide returned a different topic");
        Ok(guide)
    }

    /// Fetch an authoritative catalog for each helper call so an instance or
    /// pack reload can never reuse a stale expectation. A rejection is returned
    /// to the caller without replaying the native call.
    async fn call_native(&self, tool: &str, input: Value) -> Result<NativeResponse> {
        let response = self.backend.catalog().await?;
        ensure_native_success("catalog", &response)?;
        let catalog: NativeCatalog = serde_json::from_value(response.data)
            .context("decode native catalog for media call")?;
        ensure!(
            !catalog.instance.is_empty(),
            "native catalog has no instance"
        );
        let descriptor = catalog
            .tools
            .iter()
            .find(|entry| entry.name == tool)
            .ok_or_else(|| anyhow!("native media tool is unavailable: {tool}"))?;
        self.backend
            .call(
                tool.to_owned(),
                input,
                NativeExpect {
                    instance: catalog.instance,
                    generation: descriptor.generation.clone(),
                },
            )
            .await
    }

    pub async fn list_guide_resources(&self) -> Result<Vec<GuideResource>> {
        self.list_guides()
            .await?
            .into_iter()
            .map(|guide| {
                Ok(GuideResource {
                    uri: guide_uri(&guide.topic)?,
                    topic: guide.topic,
                    title: guide.title,
                })
            })
            .collect()
    }

    pub async fn read_guide_resource(&self, uri: &str) -> Result<ResourceContents> {
        let topic = topic_from_uri(uri)?;
        let guide = self.get_guide(&topic).await?;
        Ok(ResourceContents::text(guide.body, uri.to_owned()).with_mime_type("text/markdown"))
    }

    pub fn list_image_resources(&self) -> Vec<Resource> {
        self.artifacts
            .lock()
            .expect("media artifact mutex poisoned")
            .resources()
    }

    pub fn read_image_resource(&self, uri: &str) -> Result<ResourceContents> {
        let id = artifact_id_from_uri(uri)?;
        let image = self
            .artifacts
            .lock()
            .expect("media artifact mutex poisoned")
            .get(id)
            .ok_or_else(|| anyhow!("screenshot resource has expired"))?;
        Ok(image.resource_contents())
    }

    /// Snapshot the approved root and acquire the single-flight permit. Keep
    /// the returned session alive until the matching native Core call ends.
    pub async fn prepare(&self) -> Result<PreparedCapture> {
        let permit = tokio::time::timeout(
            self.screenshot.wait_timeout,
            self.capture_lock.clone().lock_owned(),
        )
        .await
        .context("screenshot capture is busy")?;
        let before = scan_root(&self.screenshot)?;
        Ok(PreparedCapture {
            before,
            service: self.capture_lock.clone(),
            _permit: permit,
        })
    }

    /// Finish a successful native screenshot call by finding exactly one fresh,
    /// stable image and copying it into the bounded in-memory artifact store.
    pub async fn finish(
        &self,
        capture: PreparedCapture,
        response: &NativeResponse,
    ) -> Result<ImageArtifact> {
        ensure!(
            Arc::ptr_eq(&capture.service, &self.capture_lock),
            "screenshot capture belongs to a different media service"
        );
        ensure_native_success("TakeScreenshot", response)?;
        let deadline = Instant::now() + self.screenshot.wait_timeout;
        let mut last_error = None;
        loop {
            let after = scan_root_until(&self.screenshot, deadline)?;
            let changed = changed_files(&capture.before, &after);
            if changed.len() > 1 {
                last_error = Some(anyhow!(
                    "screenshot capture is ambiguous: {} new or changed files",
                    changed.len()
                ));
            } else if let Some(path) = changed.into_iter().next() {
                match read_stable_image(&self.screenshot, &path, deadline).await {
                    Ok((mime_type, bytes)) => {
                        // Recheck the whole capture set after stability waiting;
                        // a second image appearing meanwhile makes it ambiguous.
                        let current = scan_root_until(&self.screenshot, deadline)?;
                        let changed = changed_files(&capture.before, &current);
                        ensure!(
                            changed.len() == 1 && changed[0] == path,
                            "screenshot capture is ambiguous after stability wait"
                        );
                        return self.publish(mime_type, bytes);
                    }
                    Err(error) => last_error = Some(error),
                }
            }
            if Instant::now() >= deadline {
                let reason = last_error
                    .map(|error| error.to_string())
                    .unwrap_or_else(|| "no new or changed screenshot file appeared".into());
                bail!("screenshot capture missed: {reason}");
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                continue;
            }
            tokio::time::sleep(self.screenshot.poll_interval.min(remaining)).await;
        }
    }

    fn publish(&self, mime_type: &'static str, bytes: Vec<u8>) -> Result<ImageArtifact> {
        ensure!(
            bytes.len() as u64 <= self.screenshot.max_artifact_bytes,
            "screenshot exceeds artifact store byte budget"
        );
        let bytes: Arc<[u8]> = bytes.into();
        let mut store = self
            .artifacts
            .lock()
            .expect("media artifact mutex poisoned");
        let uri = store.insert(mime_type, bytes.clone());
        Ok(ImageArtifact {
            uri,
            mime_type,
            bytes,
        })
    }
}

#[derive(Debug)]
pub struct PreparedCapture {
    before: Snapshot,
    service: Arc<AsyncMutex<()>>,
    _permit: OwnedMutexGuard<()>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileState {
    size: u64,
    modified: SystemTime,
}

type Snapshot = BTreeMap<PathBuf, FileState>;

#[derive(Debug)]
struct ArtifactStore {
    max_count: usize,
    max_bytes: u64,
    bytes: u64,
    order: VecDeque<String>,
    images: BTreeMap<String, ImageArtifact>,
}

impl ArtifactStore {
    fn new(max_count: usize, max_bytes: u64) -> Self {
        Self {
            max_count,
            max_bytes,
            bytes: 0,
            order: VecDeque::new(),
            images: BTreeMap::new(),
        }
    }

    fn insert(&mut self, mime_type: &'static str, bytes: Arc<[u8]>) -> String {
        let size = bytes.len() as u64;
        let mut uri;
        loop {
            uri = format!("{}{}", SCREENSHOT_URI_PREFIX, Uuid::new_v4());
            if !self.images.contains_key(&uri) {
                break;
            }
        }
        while self.order.len() >= self.max_count || self.bytes.saturating_add(size) > self.max_bytes
        {
            if let Some(old_uri) = self.order.pop_front() {
                if let Some(old) = self.images.remove(&old_uri) {
                    self.bytes = self.bytes.saturating_sub(old.bytes.len() as u64);
                }
            } else {
                break;
            }
        }
        self.bytes = self.bytes.saturating_add(size);
        self.order.push_back(uri.clone());
        self.images.insert(
            uri.clone(),
            ImageArtifact {
                uri: uri.clone(),
                mime_type,
                bytes,
            },
        );
        uri
    }

    fn get(&self, uri: &str) -> Option<ImageArtifact> {
        self.images.get(uri).cloned()
    }

    fn resources(&self) -> Vec<Resource> {
        self.order
            .iter()
            .filter_map(|uri| self.images.get(uri).map(ImageArtifact::resource))
            .collect()
    }
}

fn ensure_native_success(tool: &str, response: &NativeResponse) -> Result<()> {
    ensure!(response.ok, "native {tool} failed: {}", response.error);
    if let Some(result) = response.data.get("result") {
        if result.get("success").and_then(Value::as_bool) == Some(false) {
            bail!(
                "native {tool} failed: {}",
                result.get("error").unwrap_or(result)
            );
        }
    }
    Ok(())
}

fn native_output(data: &Value) -> &Value {
    data.get("result")
        .and_then(|result| result.get("output"))
        .unwrap_or(data)
}

fn parse_guide_summary(value: &Value) -> Result<GuideSummary> {
    let topic = bounded_string(value, "topic", MAX_GUIDE_TOPIC_BYTES)?;
    let title = bounded_string(value, "title", MAX_GUIDE_TITLE_BYTES)?;
    validate_topic(&topic)?;
    Ok(GuideSummary { topic, title })
}

fn parse_guide(value: &Value) -> Result<Guide> {
    let topic = bounded_string(value, "topic", MAX_GUIDE_TOPIC_BYTES)?;
    let title = bounded_string(value, "title", MAX_GUIDE_TITLE_BYTES)?;
    let body = bounded_string(value, "body", MAX_GUIDE_BODY_BYTES)?;
    validate_topic(&topic)?;
    Ok(Guide { topic, title, body })
}

fn bounded_string(value: &Value, field: &str, max: usize) -> Result<String> {
    let text = value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("native guide field {field} is missing or not a string"))?;
    ensure!(
        text.len() <= max,
        "native guide field {field} exceeds {max} bytes"
    );
    Ok(text.to_owned())
}

fn validate_topic(topic: &str) -> Result<()> {
    ensure!(!topic.is_empty(), "guide topic must not be empty");
    ensure!(
        topic.len() <= MAX_GUIDE_TOPIC_BYTES,
        "guide topic is too long"
    );
    ensure!(
        topic.chars().all(|ch| !ch.is_control()),
        "guide topic contains a control character"
    );
    Ok(())
}

pub fn guide_uri(topic: &str) -> Result<String> {
    validate_topic(topic)?;
    Ok(format!("{GUIDE_URI_PREFIX}{}", percent_encode(topic)))
}

fn topic_from_uri(uri: &str) -> Result<String> {
    let encoded = uri
        .strip_prefix(GUIDE_URI_PREFIX)
        .ok_or_else(|| anyhow!("resource URI is not an allowlisted guide URI"))?;
    ensure!(
        !encoded.is_empty() && !encoded.contains('/'),
        "invalid guide resource URI"
    );
    let topic = percent_decode(encoded)?;
    validate_topic(&topic)?;
    ensure!(
        guide_uri(&topic)? == uri,
        "guide resource URI is not canonical"
    );
    Ok(topic)
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push(hex_digit(byte >> 4));
            encoded.push(hex_digit(byte & 0x0f));
        }
    }
    encoded
}

fn percent_decode(value: &str) -> Result<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let raw = value.as_bytes();
    let mut index = 0;
    while index < raw.len() {
        if raw[index] == b'%' {
            ensure!(index + 2 < raw.len(), "invalid percent escape in guide URI");
            let high = from_hex(raw[index + 1])?;
            let low = from_hex(raw[index + 2])?;
            bytes.push((high << 4) | low);
            index += 3;
        } else {
            bytes.push(raw[index]);
            index += 1;
        }
    }
    String::from_utf8(bytes).context("guide URI is not UTF-8")
}

fn hex_digit(value: u8) -> char {
    match value {
        0..=9 => (b'0' + value) as char,
        _ => (b'A' + value - 10) as char,
    }
}

fn from_hex(value: u8) -> Result<u8> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(value - b'a' + 10),
        b'A'..=b'F' => Ok(value - b'A' + 10),
        _ => bail!("invalid percent escape in guide URI"),
    }
}

fn artifact_id_from_uri(uri: &str) -> Result<&str> {
    let id = uri
        .strip_prefix(SCREENSHOT_URI_PREFIX)
        .ok_or_else(|| anyhow!("resource URI is not an allowlisted screenshot URI"))?;
    ensure!(
        Uuid::parse_str(id).is_ok(),
        "invalid screenshot resource URI"
    );
    Ok(uri)
}

fn changed_files(before: &Snapshot, after: &Snapshot) -> Vec<PathBuf> {
    after
        .iter()
        .filter(|(path, state)| before.get(*path) != Some(*state))
        .map(|(path, _)| path.clone())
        .collect()
}

fn scan_root(config: &ScreenshotConfig) -> Result<Snapshot> {
    let mut snapshot = BTreeMap::new();
    let mut total_bytes = 0_u64;
    let started = Instant::now();
    scan_dir(
        &config.root,
        config,
        &mut snapshot,
        &mut total_bytes,
        started,
    )?;
    let screenshots = config.root.join("ScreenShots");
    let screenshots_meta = fs::symlink_metadata(&screenshots);
    if screenshots_meta
        .as_ref()
        .is_ok_and(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
    {
        scan_dir(
            &screenshots,
            config,
            &mut snapshot,
            &mut total_bytes,
            started,
        )?;
    }
    Ok(snapshot)
}

fn scan_root_until(config: &ScreenshotConfig, deadline: Instant) -> Result<Snapshot> {
    ensure!(
        Instant::now() < deadline,
        "screenshot capture wait limit exceeded"
    );
    scan_root(config)
}

fn scan_dir(
    directory: &Path,
    config: &ScreenshotConfig,
    snapshot: &mut Snapshot,
    total_bytes: &mut u64,
    started: Instant,
) -> Result<()> {
    ensure!(
        started.elapsed() <= config.wait_timeout,
        "screenshot scan exceeded time limit"
    );
    for entry in fs::read_dir(directory)
        .with_context(|| format!("scan screenshot root {}", directory.display()))?
    {
        ensure!(
            started.elapsed() <= config.wait_timeout,
            "screenshot scan exceeded time limit"
        );
        let entry = entry?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            // Never follow a link supplied by the game folder. A symlink cannot
            // become an approved capture merely by changing its extension.
            continue;
        }
        if metadata.is_dir() {
            continue;
        }
        if !metadata.is_file() || !is_screenshot_candidate(&path) {
            continue;
        }
        let canonical = fs::canonicalize(&path)?;
        ensure!(
            canonical.starts_with(&config.root),
            "screenshot path escapes approved root"
        );
        ensure!(
            snapshot.len() < config.max_scan_files,
            "screenshot scan file-count limit exceeded"
        );
        *total_bytes = total_bytes.saturating_add(metadata.len());
        ensure!(
            *total_bytes <= config.max_scan_bytes,
            "screenshot scan byte limit exceeded"
        );
        snapshot.insert(
            canonical,
            FileState {
                size: metadata.len(),
                modified: metadata.modified().unwrap_or(UNIX_EPOCH),
            },
        );
    }
    Ok(())
}

fn is_screenshot_candidate(path: &Path) -> bool {
    let Some(stem) = path.file_stem().and_then(|value| value.to_str()) else {
        return false;
    };
    if !stem.to_ascii_lowercase().starts_with("screenshot") {
        return false;
    }
    matches!(
        path.extension()
            .and_then(|value| value.to_str())
            .map(|value| value.to_ascii_lowercase())
            .as_deref(),
        Some("jpg" | "jpeg" | "png" | "webp" | "tga" | "dds")
    )
}

#[derive(Debug)]
struct FileSample {
    state: FileState,
    bytes: Vec<u8>,
}

async fn read_stable_image(
    config: &ScreenshotConfig,
    path: &Path,
    deadline: Instant,
) -> Result<(&'static str, Vec<u8>)> {
    let first = read_image_file(config, path)?;
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        bail!("screenshot file did not remain stable before timeout");
    }
    tokio::time::sleep(config.stable_for.min(remaining)).await;
    let second = read_image_file(config, path)?;
    ensure!(
        first.state == second.state && first.bytes == second.bytes,
        "screenshot file is still being written"
    );
    let mime_type = detect_mime(&second.bytes)
        .ok_or_else(|| anyhow!("screenshot file has unsupported image magic"))?;
    Ok((mime_type, second.bytes))
}

fn read_image_file(config: &ScreenshotConfig, path: &Path) -> Result<FileSample> {
    let canonical =
        fs::canonicalize(path).with_context(|| format!("resolve screenshot {}", path.display()))?;
    ensure!(
        canonical.starts_with(&config.root),
        "screenshot path escapes approved root"
    );
    let metadata = fs::symlink_metadata(&canonical)?;
    ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "screenshot path is not a regular file"
    );
    ensure!(
        metadata.len() <= config.max_image_bytes,
        "screenshot exceeds image-byte limit"
    );
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NOFOLLOW prevents a path replacement between canonicalization and
        // open from redirecting the read outside the approved root.
        options.custom_flags(0o400000);
    }
    let file = options.open(&canonical)?;
    let opened = file.metadata()?;
    ensure!(
        opened.is_file() && opened.len() <= config.max_image_bytes,
        "screenshot changed beyond image-byte limit"
    );
    let mut bytes = Vec::with_capacity(opened.len().min(config.max_image_bytes) as usize);
    file.take(config.max_image_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= config.max_image_bytes,
        "screenshot exceeds image-byte limit"
    );
    let after = fs::canonicalize(path)?;
    ensure!(
        after == canonical && after.starts_with(&config.root),
        "screenshot path changed outside approved root"
    );
    let final_metadata = fs::metadata(&after)?;
    ensure!(
        final_metadata.len() == bytes.len() as u64,
        "screenshot changed while being read"
    );
    Ok(FileSample {
        state: FileState {
            size: final_metadata.len(),
            modified: final_metadata.modified().unwrap_or(UNIX_EPOCH),
        },
        bytes,
    })
}

fn detect_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        output.push(TABLE[(first >> 2) as usize] as char);
        output.push(TABLE[((first & 0x03) << 4 | second >> 4) as usize] as char);
        if chunk.len() > 1 {
            output.push(TABLE[((second & 0x0f) << 2 | third >> 6) as usize] as char);
        } else {
            output.push('=');
        }
        if chunk.len() > 2 {
            output.push(TABLE[(third & 0x3f) as usize] as char);
        } else {
            output.push('=');
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::future::BoxFuture;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::TempDir;

    struct FakeBackend {
        calls: Mutex<Vec<(String, Value)>>,
        screenshot_root: PathBuf,
        screenshot_bytes: Vec<u8>,
        screenshot_calls: AtomicUsize,
        guides: Value,
    }

    impl FakeBackend {
        fn new(root: &Path, screenshot_bytes: Vec<u8>) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                screenshot_root: root.to_owned(),
                screenshot_bytes,
                screenshot_calls: AtomicUsize::new(0),
                guides: json!({
                    "guides": [
                        {"topic":"native-topic","title":"Native title"}
                    ]
                }),
            }
        }
    }

    impl NativeBackend for FakeBackend {
        fn status(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async { Ok(response(true, json!({}))) })
        }

        fn catalog(&self) -> BoxFuture<'static, Result<NativeResponse>> {
            Box::pin(async { Ok(catalog_response()) })
        }

        fn call(
            &self,
            tool: String,
            input: Value,
            expect: NativeExpect,
        ) -> BoxFuture<'static, Result<NativeResponse>> {
            let root = self.screenshot_root.clone();
            let bytes = self.screenshot_bytes.clone();
            let guides = self.guides.clone();
            let call_number = self.screenshot_calls.fetch_add(1, Ordering::SeqCst) + 1;
            assert_eq!(expect.instance, "fake");
            self.calls
                .lock()
                .expect("calls mutex poisoned")
                .push((tool.clone(), input));
            Box::pin(async move {
                match tool.as_str() {
                    "ListGuides" => Ok(response(
                        true,
                        json!({"result":{"success":true,"output":guides}}),
                    )),
                    "GetGuide" => Ok(response(
                        true,
                        json!({"result":{"success":true,"output":{"topic":"native-topic","title":"Native title","body":"native body"}}}),
                    )),
                    "TakeScreenshot" => {
                        fs::write(root.join(format!("ScreenShot{call_number}.jpg")), bytes)?;
                        Ok(response(
                            true,
                            json!({"result":{"success":true,"output":{"requested":true}}}),
                        ))
                    }
                    _ => Ok(response(false, json!({}))),
                }
            })
        }
    }

    fn response(ok: bool, data: Value) -> NativeResponse {
        NativeResponse {
            ok,
            id: Value::Null,
            route: "call".into(),
            error: if ok { String::new() } else { "rejected".into() },
            data,
        }
    }

    fn catalog_response() -> NativeResponse {
        response(
            true,
            json!({
                "schemaVersion": 1,
                "instance": "fake",
                "revision": "1",
                "tools": [
                    {"name":"ListGuides","input_schema":{"type":"object"},"pack":"","generation":null},
                    {"name":"GetGuide","input_schema":{"type":"object"},"pack":"","generation":null}
                ]
            }),
        )
    }

    fn service(root: &TempDir, bytes: Vec<u8>) -> Arc<MediaService> {
        let backend = Arc::new(FakeBackend::new(root.path(), bytes));
        let mut limits = ScreenshotConfig::default_limits();
        limits.poll_interval = Duration::from_millis(5);
        limits.stable_for = Duration::from_millis(5);
        limits.wait_timeout = Duration::from_millis(300);
        MediaService::new(
            backend,
            ScreenshotConfig::with_limits(root.path().to_path_buf(), limits).unwrap(),
        )
    }

    #[tokio::test]
    async fn guides_are_native_and_resources_are_typed() {
        let root = tempfile::tempdir().unwrap();
        let media = service(&root, vec![0xff, 0xd8, 0xff]);
        let guides = media.list_guide_resources().await.unwrap();
        assert_eq!(guides.len(), 1);
        assert_eq!(guides[0].uri, "tm-control://guide/native-topic");
        assert_eq!(
            media.read_guide_resource(&guides[0].uri).await.unwrap(),
            ResourceContents::text("native body", guides[0].uri.clone())
                .with_mime_type("text/markdown")
        );
        assert!(
            media
                .read_guide_resource("tm-control://guide/index")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn fresh_image_is_magic_verified_and_immutable_in_memory() {
        let root = tempfile::tempdir().unwrap();
        let media = service(&root, vec![0xff, 0xd8, 0xff, 1, 2, 3]);
        let prepared = media.prepare().await.unwrap();
        let response = media
            .backend
            .call(
                "TakeScreenshot".into(),
                json!({}),
                NativeExpect {
                    instance: "fake".into(),
                    generation: None,
                },
            )
            .await
            .unwrap();
        let artifact = media.finish(prepared, &response).await.unwrap();
        assert_eq!(artifact.mime_type(), "image/jpeg");
        assert_eq!(artifact.bytes(), &[0xff, 0xd8, 0xff, 1, 2, 3]);
        let uri = artifact.uri().to_owned();
        let image = artifact.image_block();
        assert!(matches!(image, ContentBlock::Image(_)));
        let resource = media.read_image_resource(&uri).unwrap();
        assert_eq!(resource, artifact.resource_contents());
        assert!(
            media
                .read_image_resource("tm-control://screenshot/../../outside")
                .is_err()
        );
    }

    #[tokio::test]
    async fn changed_existing_file_is_detected_and_wrong_magic_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("ScreenShot1.jpg"), b"old").unwrap();
        let media = service(&root, vec![b'P', b'N', b'G']);
        let prepared = media.prepare().await.unwrap();
        fs::write(root.path().join("ScreenShot1.jpg"), b"new-png").unwrap();
        let response = response(true, json!({}));
        assert!(media.finish(prepared, &response).await.is_err());
    }

    #[tokio::test]
    async fn concurrent_prepare_calls_are_singleflight() {
        let root = tempfile::tempdir().unwrap();
        let media = service(&root, vec![0xff, 0xd8, 0xff]);
        let first = media.prepare().await.unwrap();
        let other = media.clone();
        let waiting = tokio::spawn(async move { other.prepare().await.unwrap() });
        tokio::time::sleep(Duration::from_millis(15)).await;
        assert!(!waiting.is_finished());
        drop(first);
        let _second = waiting.await.unwrap();
    }

    #[test]
    fn base64_encoder_matches_mcp_wire_encoding() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn guide_uri_rejects_non_allowlisted_paths() {
        assert!(topic_from_uri("tm-control://guide/../secret").is_err());
        assert!(topic_from_uri("tm-control://guide/a/b").is_err());
        assert_eq!(
            guide_uri("a topic").unwrap(),
            "tm-control://guide/a%20topic"
        );
    }

    #[test]
    fn nested_native_failure_is_rejected_even_when_envelope_is_ok() {
        let failed = response(
            true,
            json!({"result":{"success":false,"error":"capture rejected"}}),
        );
        assert!(ensure_native_success("TakeScreenshot", &failed).is_err());
    }
}

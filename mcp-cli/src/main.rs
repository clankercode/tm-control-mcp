use std::{env, net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use axum::Router;
use rmcp::{ServiceExt, transport::stdio_pipes};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tracing_subscriber::EnvFilter;

use tm_control_mcp_cli::{
    Core, DEFAULT_HTTP_ADDR, DEFAULT_NATIVE_HOST, DEFAULT_NATIVE_PORT, McpAdapter, MonitorStore,
    NativeTcpClient,
};

mod tui;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Stdio,
    Http,
    Monitor,
    Doctor,
}

#[derive(Debug, Clone)]
struct Config {
    mode: Mode,
    native_host: String,
    native_port: u16,
    http_addr: SocketAddr,
    poll_ms: u64,
    events_jsonl: Option<PathBuf>,
    allowed_origins: Vec<String>,
    ascii: bool,
    export_dir: Option<PathBuf>,
    screenshots_dir: Option<PathBuf>,
}

enum ParseResult {
    Config(Config),
    Help,
    Version,
}

impl Config {
    fn parse() -> Result<ParseResult> {
        let args: Vec<String> = env::args().skip(1).collect();
        if args.len() == 1 && matches!(args[0].as_str(), "--version" | "-V") {
            return Ok(ParseResult::Version);
        }
        if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
            return Ok(ParseResult::Help);
        }
        let mut config = Self {
            mode: Mode::Stdio,
            native_host: DEFAULT_NATIVE_HOST.into(),
            native_port: DEFAULT_NATIVE_PORT,
            http_addr: DEFAULT_HTTP_ADDR.parse()?,
            poll_ms: 2000,
            events_jsonl: None,
            allowed_origins: Vec::new(),
            ascii: false,
            export_dir: None,
            screenshots_dir: None,
        };
        let mut command: Option<String> = None;
        let mut transport: Option<String> = None;
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            if index == 0 && !arg.starts_with('-') {
                anyhow::ensure!(
                    matches!(arg.as_str(), "serve" | "monitor" | "doctor"),
                    "unknown subcommand: {arg}"
                );
                command = Some(arg.clone());
                config.mode = match arg.as_str() {
                    "serve" => Mode::Stdio,
                    "monitor" => Mode::Monitor,
                    "doctor" => Mode::Doctor,
                    _ => unreachable!(),
                };
                index += 1;
                continue;
            }
            anyhow::ensure!(
                !matches!(arg.as_str(), "serve" | "monitor" | "doctor"),
                "subcommand must be first"
            );
            match arg.as_str() {
                "--transport" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("serve"),
                        "--transport is only valid with serve"
                    );
                    index += 1;
                    let value = args.get(index).context("--transport needs stdio or http")?;
                    anyhow::ensure!(
                        transport.is_none(),
                        "--transport may only be specified once"
                    );
                    anyhow::ensure!(
                        matches!(value.as_str(), "stdio" | "http"),
                        "unsupported transport: {value}"
                    );
                    transport = Some(value.clone());
                    config.mode = if value == "http" {
                        Mode::Http
                    } else {
                        Mode::Stdio
                    };
                }
                "--native-host" => {
                    anyhow::ensure!(
                        config.native_host == DEFAULT_NATIVE_HOST,
                        "--native-host may only be specified once"
                    );
                    index += 1;
                    config.native_host = args
                        .get(index)
                        .context("--native-host needs a value")?
                        .clone();
                }
                "--native-port" => {
                    anyhow::ensure!(
                        config.native_port == DEFAULT_NATIVE_PORT,
                        "--native-port may only be specified once"
                    );
                    index += 1;
                    config.native_port = args
                        .get(index)
                        .context("--native-port needs a value")?
                        .parse()
                        .context("invalid native port")?;
                }
                "--listen" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("serve")
                            || command.as_deref() == Some("monitor"),
                        "--listen is only valid with serve or monitor"
                    );
                    anyhow::ensure!(
                        config.http_addr == DEFAULT_HTTP_ADDR.parse()?,
                        "--listen may only be specified once"
                    );
                    index += 1;
                    config.http_addr = args
                        .get(index)
                        .context("--listen needs an address")?
                        .parse()
                        .context("invalid listen address")?;
                }
                "--poll-ms" => {
                    anyhow::ensure!(
                        config.poll_ms == 2000,
                        "--poll-ms may only be specified once"
                    );
                    index += 1;
                    config.poll_ms = args
                        .get(index)
                        .context("--poll-ms needs milliseconds")?
                        .parse()
                        .context("invalid poll interval")?;
                }
                "--events-jsonl" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("serve")
                            || command.as_deref() == Some("monitor"),
                        "--events-jsonl is only valid with serve or monitor"
                    );
                    anyhow::ensure!(
                        config.events_jsonl.is_none(),
                        "--events-jsonl may only be specified once"
                    );
                    index += 1;
                    config.events_jsonl = Some(
                        args.get(index)
                            .context("--events-jsonl needs a path")?
                            .into(),
                    );
                }
                "--origin" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("serve")
                            || command.as_deref() == Some("monitor"),
                        "--origin is only valid with serve or monitor"
                    );
                    index += 1;
                    config
                        .allowed_origins
                        .push(args.get(index).context("--origin needs a value")?.clone());
                }
                "--ascii" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("monitor"),
                        "--ascii is only valid with monitor"
                    );
                    anyhow::ensure!(!config.ascii, "--ascii may only be specified once");
                    config.ascii = true;
                }
                "--export-dir" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("monitor"),
                        "--export-dir is only valid with monitor"
                    );
                    anyhow::ensure!(
                        config.export_dir.is_none(),
                        "--export-dir may only be specified once"
                    );
                    index += 1;
                    config.export_dir =
                        Some(args.get(index).context("--export-dir needs a path")?.into());
                }
                "--screenshots-dir" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("serve")
                            || command.as_deref() == Some("monitor"),
                        "--screenshots-dir is only valid with serve or monitor"
                    );
                    anyhow::ensure!(
                        config.screenshots_dir.is_none(),
                        "--screenshots-dir may only be specified once"
                    );
                    index += 1;
                    config.screenshots_dir = Some(
                        args.get(index)
                            .context("--screenshots-dir needs a path")?
                            .into(),
                    );
                }
                "--help" | "-h" => return Ok(ParseResult::Help),
                "--version" | "-V" => return Ok(ParseResult::Version),
                "--stdio" | "--http" | "--tui" => anyhow::bail!(
                    "contradictory legacy flag {arg}; use a subcommand and --transport"
                ),
                value => anyhow::bail!("unknown argument: {value}"),
            }
            index += 1;
        }
        if command.is_none()
            && (transport.is_some()
                || config.events_jsonl.is_some()
                || !config.allowed_origins.is_empty()
                || config.export_dir.is_some()
                || config.screenshots_dir.is_some()
                || config.ascii)
        {
            anyhow::bail!("options requiring a subcommand were provided without serve or monitor");
        }
        if command.as_deref() == Some("doctor")
            && (config.http_addr != DEFAULT_HTTP_ADDR.parse()? || config.poll_ms != 2000)
        {
            anyhow::bail!("doctor accepts native connection options only");
        }
        Ok(ParseResult::Config(config))
    }
}

fn usage() -> &'static str {
    "tm-control-mcp [--version]\n\nCommands:\n  (default)                         MCP stdio\n  serve [--transport stdio|http]   MCP stdio or loopback Streamable HTTP\n  monitor                           HTTP plus terminal telemetry monitor\n  doctor                            check native bridge status and catalog\n\nOptions:\n  --native-host HOST --native-port PORT --poll-ms MS\n  --listen ADDR --origin ORIGIN --events-jsonl PATH\n  --ascii --export-dir PATH (monitor)\n  --screenshots-dir PATH (serve/monitor)\n"
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();
    let parsed = Config::parse()?;
    let config = match parsed {
        ParseResult::Help => {
            print!("{}", usage());
            return Ok(());
        }
        ParseResult::Version => {
            println!("tm-control-mcp {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        ParseResult::Config(config) => config,
    };
    let cancellation = CancellationToken::new();
    let monitor = MonitorStore::new(config.events_jsonl.clone());
    let backend = Arc::new(NativeTcpClient::new(
        config.native_host.clone(),
        config.native_port,
    ));
    let core = Core::new(backend, monitor.clone());
    let adapter = McpAdapter::with_media_root(core.clone(), config.screenshots_dir.clone())?;
    core.start_catalog_poller(
        Duration::from_millis(config.poll_ms.max(100)),
        cancellation.clone(),
    );
    let result = match config.mode {
        Mode::Doctor => run_doctor(&core).await,
        Mode::Stdio => run_stdio(adapter).await,
        Mode::Http => {
            run_http(
                adapter,
                config.http_addr,
                config.allowed_origins,
                cancellation.clone(),
            )
            .await
        }
        Mode::Monitor => run_monitor(core, adapter, config, cancellation.clone()).await,
    };
    monitor.shutdown(Duration::from_secs(2)).await;
    result
}

async fn run_doctor(core: &Arc<Core>) -> Result<()> {
    let status = core.status().await.context("native bridge status failed")?;
    anyhow::ensure!(status.ok, "native bridge status rejected: {}", status.error);
    let catalog = core
        .refresh_catalog()
        .await
        .context("native catalog failed")?;
    println!(
        "{}",
        serde_json::json!({"ok":true,"status":status.data,"catalog":catalog.identity,"tools":catalog.tools.len()})
    );
    Ok(())
}

async fn run_stdio(adapter: McpAdapter) -> Result<()> {
    let (reader, writer) = stdio_pipes();
    let service = adapter
        .serve((reader, writer))
        .await
        .context("start MCP stdio server")?;
    service.waiting().await.context("MCP stdio server")?;
    Ok(())
}

async fn bind_http(address: SocketAddr) -> Result<TcpListener> {
    anyhow::ensure!(
        address.ip().is_loopback(),
        "HTTP server must bind to a loopback address"
    );
    TcpListener::bind(address)
        .await
        .with_context(|| format!("bind HTTP {address}"))
}

fn http_router(
    adapter: McpAdapter,
    address: SocketAddr,
    origins: Vec<String>,
    cancellation: CancellationToken,
) -> Router {
    let config = rmcp::transport::streamable_http_server::StreamableHttpServerConfig::default()
        .with_allowed_hosts([
            address.ip().to_string(),
            format!("localhost:{}", address.port()),
        ])
        .with_allowed_origins(origins)
        .enforce_origin_validation()
        .with_legacy_session_mode(true)
        .with_json_response(true)
        .with_cancellation_token(cancellation);
    let service = rmcp::transport::streamable_http_server::StreamableHttpService::<
        McpAdapter,
        rmcp::transport::streamable_http_server::session::local::LocalSessionManager,
    >::new(move || Ok(adapter.clone()), Default::default(), config);
    Router::new().nest_service("/mcp", service)
}

async fn serve_http(
    adapter: McpAdapter,
    listener: TcpListener,
    address: SocketAddr,
    origins: Vec<String>,
    cancellation: CancellationToken,
) -> Result<()> {
    tracing::info!(%address, "MCP Streamable HTTP listening");
    axum::serve(
        listener,
        http_router(adapter, address, origins, cancellation.clone()),
    )
    .with_graceful_shutdown(async move {
        cancellation.cancelled().await;
    })
    .await?;
    Ok(())
}

async fn run_http(
    adapter: McpAdapter,
    address: SocketAddr,
    origins: Vec<String>,
    cancellation: CancellationToken,
) -> Result<()> {
    let listener = bind_http(address).await?;
    serve_http(adapter, listener, address, origins, cancellation).await
}

async fn wait_headless(cancellation: CancellationToken) {
    tokio::select! { _ = cancellation.cancelled() => {}, result = tokio::signal::ctrl_c() => { if let Err(error) = result { tracing::debug!(%error, "headless shutdown signal unavailable"); } } }
}

async fn await_http(
    mut task: tokio::task::JoinHandle<Result<()>>,
    cancellation: CancellationToken,
) -> Result<()> {
    cancellation.cancel();
    match tokio::time::timeout(Duration::from_secs(5), &mut task).await {
        Ok(result) => result.context("HTTP task panicked")??,
        Err(_) => {
            task.abort();
            return Err(anyhow::anyhow!("HTTP server did not stop within 5 seconds"));
        }
    };
    Ok(())
}

async fn run_monitor(
    core: Arc<Core>,
    adapter: McpAdapter,
    config: Config,
    cancellation: CancellationToken,
) -> Result<()> {
    // Bind before touching the terminal so an address error remains visible and actionable.
    let listener = bind_http(config.http_addr).await?;
    let mut http_task = tokio::spawn(serve_http(
        adapter,
        listener,
        config.http_addr,
        config.allowed_origins.clone(),
        cancellation.clone(),
    ));
    let mut tui_task = Box::pin(tui::run(
        core,
        cancellation.clone(),
        config.ascii,
        config.export_dir,
    ));
    tokio::select! {
        tui_result = &mut tui_task => {
            match tui_result {
                Ok(()) => await_http(http_task, cancellation).await,
                Err(error) => {
                    tracing::error!(%error, "terminal monitor unavailable; continuing headless");
                    wait_headless(cancellation.clone()).await;
                    await_http(http_task, cancellation).await
                }
            }
        }
        http_result = &mut http_task => {
            cancellation.cancel();
            let _ = tui_task.await;
            http_result.context("HTTP task panicked")?
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_names_only_supported_modes() {
        assert!(usage().contains("monitor"));
        assert!(!usage().contains("--tui"));
    }
}

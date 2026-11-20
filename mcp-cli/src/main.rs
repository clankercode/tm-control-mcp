use std::{env, net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use axum::Router;
use rmcp::{ServiceExt, transport::stdio_pipes};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tracing_subscriber::EnvFilter;

use tm_control_mcp_cli::{
    Core, DEFAULT_HTTP_ADDR, DEFAULT_NATIVE_HOST, DEFAULT_NATIVE_PORT, McpAdapter, MonitorStore,
    NativeTcpClient, audit,
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
    /// `monitor --serve`: bind an auditable HTTP listener instead of
    /// attaching to an existing server.
    monitor_serve: bool,
    /// `monitor --attach ADDR`: the existing server to audit.
    attach_addr: Option<SocketAddr>,
}

enum ParseResult {
    Config(Config),
    Help,
    Version,
}

impl Config {
    fn parse() -> Result<ParseResult> {
        let args: Vec<String> = env::args().skip(1).collect();
        Self::parse_from(args)
    }

    fn parse_from(args: Vec<String>) -> Result<ParseResult> {
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
            monitor_serve: false,
            attach_addr: None,
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
                "--serve" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("monitor"),
                        "--serve is only valid with monitor"
                    );
                    anyhow::ensure!(!config.monitor_serve, "--serve may only be specified once");
                    config.monitor_serve = true;
                }
                "--attach" => {
                    anyhow::ensure!(
                        command.as_deref() == Some("monitor"),
                        "--attach is only valid with monitor"
                    );
                    anyhow::ensure!(
                        config.attach_addr.is_none(),
                        "--attach may only be specified once"
                    );
                    index += 1;
                    config.attach_addr = Some(
                        args.get(index)
                            .context("--attach needs an address")?
                            .parse()
                            .context("invalid attach address")?,
                    );
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
        if config.monitor_serve && config.attach_addr.is_some() {
            anyhow::bail!("--serve starts a listener and --attach audits one; pick either");
        }
        // Validation is post-parse so flag order never changes the contract.
        if matches!(config.mode, Mode::Monitor) && !config.monitor_serve {
            let serving = "use `monitor --serve` to start an auditable HTTP listener";
            anyhow::ensure!(
                config.http_addr == DEFAULT_HTTP_ADDR.parse()?,
                "--listen configures the monitor's own HTTP server; {serving}"
            );
            anyhow::ensure!(
                config.events_jsonl.is_none(),
                "--events-jsonl is written by the server process; {serving}"
            );
            anyhow::ensure!(
                config.allowed_origins.is_empty(),
                "--origin configures the HTTP server; {serving}"
            );
            anyhow::ensure!(
                config.screenshots_dir.is_none(),
                "--screenshots-dir configures the HTTP server; {serving}"
            );
            anyhow::ensure!(
                config.native_host == DEFAULT_NATIVE_HOST,
                "--native-host configures the server's native bridge connection; {serving}"
            );
            anyhow::ensure!(
                config.native_port == DEFAULT_NATIVE_PORT,
                "--native-port configures the server's native bridge connection; {serving}"
            );
            anyhow::ensure!(
                config.poll_ms == 2000,
                "--poll-ms configures the server's catalog poller; {serving}"
            );
        }
        Ok(ParseResult::Config(config))
    }
}

fn usage() -> &'static str {
    "tm-control-mcp [--version]\n\nCommands:\n  (default)                         MCP stdio\n  serve [--transport stdio|http]    MCP stdio or loopback Streamable HTTP\n  monitor [--attach ADDR]           terminal monitor auditing an existing\n                                    MCP HTTP server (default 127.0.0.1:30007)\n  monitor --serve [--listen ADDR]   start an auditable HTTP MCP server plus\n                                    the terminal monitor\n  doctor                            check native bridge status and catalog\n\nOptions:\n  --native-host HOST --native-port PORT --poll-ms MS (server modes)\n  --listen ADDR --origin ORIGIN --events-jsonl PATH\n      --screenshots-dir PATH (serve, monitor --serve)\n  --ascii --export-dir PATH (monitor)\n"
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
    let result = if matches!(config.mode, Mode::Monitor) && !config.monitor_serve {
        // Attach mode is a pure observer: no MCP listener, no native client.
        run_monitor_attach(&config, cancellation.clone()).await
    } else {
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
    };
    result
}

/// Attach the terminal monitor to an already-running MCP HTTP server and
/// audit its traffic. The process never creates an MCP listener, a native
/// bridge client, or a catalog poller; it only reads `/monitor/snapshot`.
async fn run_monitor_attach(config: &Config, cancellation: CancellationToken) -> Result<()> {
    let target = config
        .attach_addr
        .unwrap_or_else(|| DEFAULT_HTTP_ADDR.parse().expect("default attach address"));
    // Probe before touching the terminal so an unreachable or foreign server
    // surfaces an actionable error instead of an empty TUI.
    let probe = tokio::time::timeout(audit::PROBE_TIMEOUT, audit::fetch_snapshot(target))
        .await
        .map_err(|_| audit::FetchError::Timeout(target))
        .and_then(|probe| probe);
    let first = probe.map_err(|error| anyhow::anyhow!("{}", error.attach_hint(target)))?;
    let remote = Arc::new(audit::RemoteMonitor::new());
    remote.update(first);
    let mut poller = audit::spawn_poller(remote.clone(), target, cancellation.clone());
    let tui_result = tui::run_attached(
        remote,
        target,
        cancellation.clone(),
        config.ascii,
        config.export_dir.clone(),
    )
    .await;
    cancellation.cancel();
    if tokio::time::timeout(Duration::from_secs(1), &mut poller)
        .await
        .is_err()
    {
        poller.abort();
    }
    tui_result
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
        .with_allowed_origins(origins.clone())
        .enforce_origin_validation()
        .with_legacy_session_mode(true)
        .with_json_response(true)
        .with_cancellation_token(cancellation);
    // Every Streamable HTTP listener also serves the read-only audit
    // endpoint `tm-control-mcp monitor` attaches to by default.
    let audit_state = audit::AuditState::new(
        adapter.core.monitor(),
        audit::allowed_hosts(address),
        origins,
    );
    let service = rmcp::transport::streamable_http_server::StreamableHttpService::<
        McpAdapter,
        rmcp::transport::streamable_http_server::session::local::LocalSessionManager,
    >::new(move || Ok(adapter.clone()), Default::default(), config);
    Router::new()
        .nest_service("/mcp", service)
        .merge(audit::audit_router(audit_state))
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
    let http_address = listener.local_addr().context("read HTTP listen address")?;
    let mut http_task = tokio::spawn(serve_http(
        adapter,
        listener,
        http_address,
        config.allowed_origins.clone(),
        cancellation.clone(),
    ));
    let mut tui_task = Box::pin(tui::run(
        core,
        cancellation.clone(),
        config.ascii,
        config.export_dir,
        http_address,
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

    fn parse(args: &[&str]) -> Result<Config> {
        match Config::parse_from(args.iter().map(|arg| arg.to_string()).collect())? {
            ParseResult::Config(config) => Ok(config),
            ParseResult::Help | ParseResult::Version => anyhow::bail!("expected a config"),
        }
    }

    #[test]
    fn usage_names_only_supported_modes() {
        assert!(usage().contains("monitor"));
        assert!(usage().contains("--attach"));
        assert!(usage().contains("--serve"));
        assert!(!usage().contains("--tui"));
    }

    #[test]
    fn monitor_defaults_to_attaching_an_existing_server() {
        let config = parse(&["monitor"]).unwrap();
        assert!(matches!(config.mode, Mode::Monitor));
        assert!(!config.monitor_serve);
        assert!(
            config.attach_addr.is_none(),
            "default target resolves at run time"
        );
        let config = parse(&["monitor", "--ascii", "--export-dir", "/tmp"]).unwrap();
        assert!(config.ascii);
        assert_eq!(config.export_dir, Some(PathBuf::from("/tmp")));
    }

    #[test]
    fn monitor_serve_and_attach_parse_and_stay_mutually_exclusive() {
        let config = parse(&["monitor", "--serve"]).unwrap();
        assert!(config.monitor_serve);
        let config = parse(&["monitor", "--attach", "127.0.0.1:30100"]).unwrap();
        assert_eq!(config.attach_addr, Some("127.0.0.1:30100".parse().unwrap()));
        let error = parse(&["monitor", "--serve", "--attach", "127.0.0.1:30007"])
            .unwrap_err()
            .to_string();
        assert!(error.contains("pick either"), "{error}");
    }

    #[test]
    fn attach_mode_rejects_server_only_flags_with_a_serve_hint() {
        for args in [
            vec!["monitor", "--listen", "127.0.0.1:30110"],
            vec!["monitor", "--native-host", "127.0.0.2"],
            vec!["monitor", "--native-port", "1234"],
            vec!["monitor", "--poll-ms", "500"],
            vec!["monitor", "--origin", "https://example.invalid"],
            vec!["monitor", "--events-jsonl", "/tmp/events.jsonl"],
            vec!["monitor", "--screenshots-dir", "/tmp/Trackmania"],
        ] {
            let error = parse(&args).unwrap_err().to_string();
            assert!(error.contains("--serve"), "{args:?}: {error}");
        }
    }

    #[test]
    fn serve_mode_keeps_every_previous_monitor_flag() {
        parse(&[
            "monitor",
            "--serve",
            "--listen",
            "127.0.0.1:30111",
            "--native-port",
            "1234",
            "--poll-ms",
            "500",
            "--events-jsonl",
            "/tmp/events.jsonl",
            "--origin",
            "http://localhost:30111",
            "--ascii",
        ])
        .unwrap();
        parse(&[
            "serve",
            "--transport",
            "http",
            "--listen",
            "127.0.0.1:30112",
        ])
        .unwrap();
    }

    #[test]
    fn attach_and_serve_flags_require_the_monitor_subcommand() {
        assert!(parse(&["--attach", "127.0.0.1:30007"]).is_err());
        assert!(parse(&["serve", "--attach", "127.0.0.1:30007"]).is_err());
        assert!(parse(&["doctor", "--serve"]).is_err());
        assert!(parse(&["monitor", "--attach"]).is_err());
        assert!(parse(&["monitor", "--attach", "not-an-address"]).is_err());
    }
}

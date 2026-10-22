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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Stdio,
    Http,
    Tui,
    Doctor,
}

#[derive(Debug)]
struct Config {
    mode: Mode,
    native_host: String,
    native_port: u16,
    http_addr: SocketAddr,
    poll_ms: u64,
    events_jsonl: Option<PathBuf>,
    allowed_origins: Vec<String>,
}

impl Config {
    fn parse() -> Result<Self> {
        let mut config = Self {
            mode: Mode::Stdio,
            native_host: DEFAULT_NATIVE_HOST.into(),
            native_port: DEFAULT_NATIVE_PORT,
            http_addr: DEFAULT_HTTP_ADDR.parse()?,
            poll_ms: 2000,
            events_jsonl: None,
            allowed_origins: vec![],
        };
        let args: Vec<String> = env::args().skip(1).collect();
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "serve" => config.mode = Mode::Stdio,
                "monitor" => config.mode = Mode::Tui,
                "doctor" => config.mode = Mode::Doctor,
                "--transport" => {
                    index += 1;
                    config.mode = match args
                        .get(index)
                        .context("--transport needs stdio or http")?
                        .as_str()
                    {
                        "stdio" => Mode::Stdio,
                        "http" => Mode::Http,
                        value => anyhow::bail!("unsupported transport: {value}"),
                    };
                }
                "--stdio" => config.mode = Mode::Stdio,
                "--http" => config.mode = Mode::Http,
                "--tui" => config.mode = Mode::Tui,
                "--native-host" => {
                    index += 1;
                    config.native_host = args
                        .get(index)
                        .context("--native-host needs a value")?
                        .clone();
                }
                "--native-port" => {
                    index += 1;
                    config.native_port = args
                        .get(index)
                        .context("--native-port needs a value")?
                        .parse()?;
                }
                "--listen" => {
                    index += 1;
                    config.http_addr =
                        args.get(index).context("--listen needs a value")?.parse()?;
                }
                "--poll-ms" => {
                    index += 1;
                    config.poll_ms = args
                        .get(index)
                        .context("--poll-ms needs a value")?
                        .parse()?;
                }
                "--events-jsonl" => {
                    index += 1;
                    config.events_jsonl = Some(
                        args.get(index)
                            .context("--events-jsonl needs a value")?
                            .into(),
                    );
                }
                "--origin" => {
                    index += 1;
                    config
                        .allowed_origins
                        .push(args.get(index).context("--origin needs a value")?.clone());
                }
                "--help" | "-h" => {
                    eprintln!(
                        "tm-control-mcp [serve --transport stdio|http | monitor | doctor] [--native-host HOST] [--native-port PORT] [--listen ADDR] [--events-jsonl PATH] [--origin ORIGIN]"
                    );
                    std::process::exit(0);
                }
                value => anyhow::bail!("unknown argument: {value}"),
            }
            index += 1;
        }
        Ok(config)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Never write tracing to stdout: stdout is the MCP stdio transport.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();
    let config = Config::parse()?;
    let cancellation = CancellationToken::new();
    let monitor = MonitorStore::new(config.events_jsonl.clone());
    let backend = Arc::new(NativeTcpClient::new(config.native_host, config.native_port));
    let core = Core::new(backend, monitor);
    core.start_catalog_poller(
        Duration::from_millis(config.poll_ms.max(100)),
        cancellation.clone(),
    );

    match config.mode {
        Mode::Doctor => {
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
        Mode::Stdio => run_stdio(McpAdapter::new(core)).await,
        Mode::Http => {
            run_http(
                McpAdapter::new(core),
                config.http_addr,
                config.allowed_origins,
                cancellation,
            )
            .await
        }
        Mode::Tui => run_tui(core, config.http_addr, config.allowed_origins, cancellation).await,
    }
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

async fn run_http(
    adapter: McpAdapter,
    address: SocketAddr,
    origins: Vec<String>,
    cancellation: CancellationToken,
) -> Result<()> {
    anyhow::ensure!(
        address.ip().is_loopback(),
        "HTTP server must bind to a loopback address"
    );
    let config = rmcp::transport::streamable_http_server::StreamableHttpServerConfig::default()
        .with_allowed_hosts([
            address.ip().to_string(),
            format!("localhost:{}", address.port()),
        ])
        .with_allowed_origins(origins)
        .enforce_origin_validation()
        .with_legacy_session_mode(true)
        .with_json_response(true)
        .with_cancellation_token(cancellation.clone());
    let service = rmcp::transport::streamable_http_server::StreamableHttpService::<
        McpAdapter,
        rmcp::transport::streamable_http_server::session::local::LocalSessionManager,
    >::new(move || Ok(adapter.clone()), Default::default(), config);
    let router = Router::new().nest_service("/mcp", service);
    let listener = TcpListener::bind(address)
        .await
        .with_context(|| format!("bind HTTP {address}"))?;
    tracing::info!(%address, "MCP Streamable HTTP listening");
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            cancellation.cancelled().await;
        })
        .await?;
    Ok(())
}

async fn run_tui(
    core: Arc<Core>,
    address: SocketAddr,
    origins: Vec<String>,
    cancellation: CancellationToken,
) -> Result<()> {
    let http_core = core.clone();
    let http_cancel = cancellation.clone();
    tokio::spawn(async move {
        let _ = run_http(McpAdapter::new(http_core), address, origins, http_cancel).await;
    });
    tui::run(core, cancellation).await
}

mod tui {
    use anyhow::Result;
    use crossterm::{
        event::{self, Event as CEvent, KeyCode, KeyEventKind},
        execute,
        terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
    };
    use ratatui::{
        Terminal,
        backend::CrosstermBackend,
        layout::{Constraint, Direction, Layout},
        style::{Color, Style},
        text::{Line, Span},
        widgets::{Block, Borders, List, ListItem, Paragraph},
    };
    use std::sync::Arc;
    use tm_control_mcp_cli::{Core, Event};
    use tokio_util::sync::CancellationToken;

    pub async fn run(core: Arc<Core>, cancellation: CancellationToken) -> Result<()> {
        enable_raw_mode()?;
        let mut stdout = std::io::stdout();
        execute!(stdout, EnterAlternateScreen)?;
        let result = tokio::task::spawn_blocking(move || draw_loop(core, cancellation)).await?;
        disable_raw_mode()?;
        execute!(std::io::stdout(), LeaveAlternateScreen)?;
        result
    }

    fn draw_loop(core: Arc<Core>, cancellation: CancellationToken) -> Result<()> {
        let backend = CrosstermBackend::new(std::io::stdout());
        let mut terminal = Terminal::new(backend)?;
        let mut selected = 0usize;
        let mut filter = String::new();
        let mut paused = false;
        let mut follow = true;
        loop {
            let events = core.monitor().snapshot();
            if follow && !events.is_empty() {
                selected = events.len().saturating_sub(1);
            }
            terminal.draw(|frame| {
                let areas = Layout::default().direction(Direction::Vertical).constraints([Constraint::Length(3), Constraint::Min(4), Constraint::Length(6)]).split(frame.area());
                frame.render_widget(Paragraph::new(Line::from(vec![Span::styled("tm-control-mcp monitor", Style::default().fg(Color::Cyan)), Span::raw(format!("  events={} filter='{}' follow={} paused={}  q=quit p=pause f=follow /=filter", events.len(), filter, follow, paused))])).block(Block::default().borders(Borders::ALL)), areas[0]);
                let visible: Vec<(usize, &Event)> = events.iter().enumerate().filter(|(_, event)| filter.is_empty() || event.method.contains(&filter) || event.tool.as_deref().is_some_and(|tool| tool.contains(&filter))).collect();
                let items: Vec<ListItem> = visible.iter().map(|(_, event)| ListItem::new(format!("{} {} {} {}ms", event.status, event.tool.as_deref().unwrap_or("-"), event.request_id, event.ended_ms.saturating_sub(event.started_ms)))).collect();
                frame.render_widget(List::new(items).block(Block::default().borders(Borders::ALL).title("calls")), areas[1]);
                let detail = events.get(selected).map(|event| format!("id={}\\nmethod={}\\ntool={}\\nargs={}\\nresult={}", event.invocation_id, event.method, event.tool.as_deref().unwrap_or("-"), event.arguments, event.result)).unwrap_or_else(|| "No calls yet".into());
                frame.render_widget(Paragraph::new(detail).block(Block::default().borders(Borders::ALL).title("detail")), areas[2]);
            })?;
            if event::poll(std::time::Duration::from_millis(150))? {
                if let CEvent::Key(key) = event::read()? {
                    if key.kind != KeyEventKind::Press {
                        continue;
                    }
                    match key.code {
                        KeyCode::Char('q') | KeyCode::Esc => {
                            cancellation.cancel();
                            break;
                        }
                        KeyCode::Char('p') => paused = !paused,
                        KeyCode::Char('f') => follow = !follow,
                        KeyCode::Char('/') => filter.clear(),
                        KeyCode::Char(ch) if !paused => filter.push(ch),
                        KeyCode::Up => selected = selected.saturating_sub(1),
                        KeyCode::Down => selected = selected.saturating_add(1),
                        _ => {}
                    }
                }
            }
        }
        Ok(())
    }
}

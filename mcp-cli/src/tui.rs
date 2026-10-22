//! Terminal monitor. The model is independent of crossterm so TestBackend tests are deterministic.

use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use crossterm::{
    event::{self, Event as CEvent, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Terminal,
    backend::{Backend, CrosstermBackend},
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{
        Block, Borders, List, ListItem, ListState, Paragraph, Scrollbar, ScrollbarOrientation,
        ScrollbarState, Wrap,
    },
};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use tm_control_mcp_cli::{Core, Event, MonitorStats};

const TICK: Duration = Duration::from_millis(100);
const MAX_DETAILS_LINES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterMode {
    None,
    Input,
}

#[derive(Debug)]
pub struct App {
    pub events: Vec<Arc<Event>>,
    pub selected: usize,
    pub details_offset: usize,
    pub paused: bool,
    pub follow: bool,
    pub filter_mode: FilterMode,
    pub filter: String,
    pub ascii: bool,
    pub export_dir: Option<PathBuf>,
    pub status: String,
    pub status_until: Option<Instant>,
    pub stats: MonitorStats,
    pub last_update: Instant,
}

impl App {
    pub fn new(ascii: bool, export_dir: Option<PathBuf>) -> Self {
        Self {
            events: Vec::new(),
            selected: 0,
            details_offset: 0,
            paused: false,
            follow: true,
            filter_mode: FilterMode::None,
            filter: String::new(),
            ascii,
            export_dir,
            status: "connecting to native bridge".into(),
            status_until: None,
            stats: MonitorStats::default(),
            last_update: Instant::now(),
        }
    }

    pub fn update(&mut self, events: Vec<Arc<Event>>, stats: MonitorStats) {
        if self.paused {
            return;
        }
        self.events = events;
        self.stats = stats;
        self.last_update = Instant::now();
        let visible = self.visible_indices();
        if visible.is_empty() {
            self.selected = 0;
        } else if self.follow {
            self.selected = visible.len() - 1;
        } else {
            self.selected = self.selected.min(visible.len() - 1);
        }
    }

    pub fn visible_indices(&self) -> Vec<usize> {
        self.events
            .iter()
            .enumerate()
            .filter_map(|(index, event)| self.matches(event).then_some(index))
            .collect()
    }

    fn matches(&self, event: &Event) -> bool {
        let query = self.filter.trim();
        if query.is_empty() {
            return true;
        }
        let lower = query.to_ascii_lowercase();
        if let Some(value) = lower.strip_prefix("status:") {
            return event.status.to_ascii_lowercase().contains(value.trim());
        }
        if let Some(value) = lower.strip_prefix("tool:") {
            return event
                .tool
                .as_deref()
                .unwrap_or("")
                .to_ascii_lowercase()
                .contains(value.trim());
        }
        if lower == "error" || lower == "errors" {
            return event.status.contains("error")
                || event.status.contains("fail")
                || event.status == "tool_error";
        }
        [
            event.method.as_str(),
            event.tool.as_deref().unwrap_or(""),
            event.status.as_str(),
            event.connection_id.as_str(),
            event.request_id.as_str(),
        ]
        .iter()
        .any(|value| value.to_ascii_lowercase().contains(&lower))
    }

    fn selected_event(&self) -> Option<&Event> {
        self.visible_indices()
            .get(self.selected)
            .and_then(|index| self.events.get(*index))
            .map(Arc::as_ref)
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Action {
        if key.kind != KeyEventKind::Press {
            return Action::Continue;
        }
        if self.filter_mode == FilterMode::Input {
            match key.code {
                KeyCode::Esc => {
                    self.filter_mode = FilterMode::None;
                    self.status = "filter cancelled".into();
                }
                KeyCode::Enter => {
                    self.filter_mode = FilterMode::None;
                    self.status = format!("filter: {}", self.filter);
                }
                KeyCode::Backspace => {
                    self.filter.pop();
                    self.selected = 0;
                }
                KeyCode::Char(ch) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.filter.push(ch);
                    self.selected = 0;
                }
                _ => {}
            }
            return Action::Continue;
        }
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => return Action::Quit,
            KeyCode::Char('p') | KeyCode::Char(' ') => {
                self.paused = !self.paused;
                self.status = if self.paused {
                    "paused: frozen snapshot"
                } else {
                    "resumed"
                }
                .into();
            }
            KeyCode::Char('f') => {
                self.follow = !self.follow;
                self.status = format!("follow {}", if self.follow { "on" } else { "off" });
            }
            KeyCode::Char('/') => {
                self.filter_mode = FilterMode::Input;
                self.status = "filter input: status:error, tool:name, error, or text".into();
            }
            KeyCode::Char('c') => {
                self.filter.clear();
                self.selected = 0;
                self.status = "filter cleared".into();
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.selected = self.selected.saturating_sub(1);
                self.follow = false;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.selected = self
                    .selected
                    .saturating_add(1)
                    .min(self.visible_indices().len().saturating_sub(1));
                self.follow = false;
            }
            KeyCode::PageUp => {
                self.selected = self.selected.saturating_sub(10);
                self.follow = false;
            }
            KeyCode::PageDown => {
                self.selected = self
                    .selected
                    .saturating_add(10)
                    .min(self.visible_indices().len().saturating_sub(1));
                self.follow = false;
            }
            KeyCode::Char('[') => self.details_offset = self.details_offset.saturating_sub(5),
            KeyCode::Char(']') => self.details_offset = self.details_offset.saturating_add(5),
            KeyCode::Char('e') => self.export_selected(),
            _ => {}
        }
        Action::Continue
    }

    fn export_selected(&mut self) {
        let Some(event) = self.selected_event().cloned() else {
            self.status = "nothing selected to export".into();
            return;
        };
        let Some(dir) = self.export_dir.clone() else {
            self.status = "payload export disabled; pass --export-dir".into();
            return;
        };
        match export_event(&dir, &event) {
            Ok(path) => self.status = format!("payload exported: {}", path.display()),
            Err(error) => self.status = format!("export failed: {error}"),
        }
        self.status_until = Some(Instant::now() + Duration::from_secs(5));
    }

    fn status_line(&self) -> String {
        let selected = self
            .selected_event()
            .map(|event| format!("{} {}", icon(self.ascii, event), event.status))
            .unwrap_or_else(|| "idle".into());
        format!(
            "{}  {}  events {}/{}  active {}  drops {} lag {} log {}  {}",
            if self.paused { "PAUSED" } else { "LIVE" },
            selected,
            self.events.len(),
            tm_control_mcp_cli::monitor::MAX_EVENTS,
            self.stats.active,
            self.stats.dropped + self.stats.jsonl_dropped,
            self.stats.lagged,
            self.stats.jsonl_errors,
            self.status
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Continue,
    Quit,
}

pub async fn run(
    core: Arc<Core>,
    cancellation: CancellationToken,
    ascii: bool,
    export_dir: Option<PathBuf>,
) -> Result<()> {
    let terminal = TerminalGuard::enter().context("enter terminal monitor")?;
    let result = tokio::task::spawn_blocking(move || {
        draw_loop(core, cancellation.clone(), terminal, ascii, export_dir)
    })
    .await?;
    result
}

fn draw_loop(
    core: Arc<Core>,
    cancellation: CancellationToken,
    mut terminal: TerminalGuard,
    ascii: bool,
    export_dir: Option<PathBuf>,
) -> Result<()> {
    let mut app = App::new(ascii, export_dir);
    loop {
        if !app.paused {
            app.update(core.monitor().snapshot_shared(), core.monitor().stats());
        }
        terminal
            .draw(|frame| render(frame, &mut app))
            .context("render monitor")?;
        if cancellation.is_cancelled() {
            return Ok(());
        }
        if event::poll(TICK)? {
            if let CEvent::Key(key) = event::read()? {
                if app.handle_key(key) == Action::Quit {
                    cancellation.cancel();
                    return Ok(());
                }
            }
        }
    }
}

struct TerminalGuard {
    terminal: Terminal<CrosstermBackend<io::Stdout>>,
    active: bool,
}

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("enable raw mode")?;
        let mut stdout = io::stdout();
        if let Err(error) = execute!(stdout, EnterAlternateScreen) {
            let _ = disable_raw_mode();
            return Err(error.into());
        }
        let terminal = match Terminal::new(CrosstermBackend::new(stdout)) {
            Ok(terminal) => terminal,
            Err(error) => {
                let _ = disable_raw_mode();
                let _ = execute!(io::stdout(), LeaveAlternateScreen);
                return Err(error.into());
            }
        };
        Ok(Self {
            terminal,
            active: true,
        })
    }

    fn draw<F>(&mut self, draw: F) -> io::Result<()>
    where
        F: FnOnce(&mut ratatui::Frame<'_>),
    {
        self.terminal.draw(draw).map(|_| ())
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        if self.active {
            let _ = disable_raw_mode();
            let _ = execute!(self.terminal.backend_mut(), LeaveAlternateScreen);
            let _ = self.terminal.show_cursor();
            self.active = false;
        }
    }
}

fn icon(ascii: bool, event: &Event) -> &'static str {
    if ascii {
        if event.is_active() {
            "~"
        } else if event.status.contains("error") || event.status.contains("fail") {
            "!"
        } else {
            ">"
        }
    } else if event.is_active() {
        "◌"
    } else if event.status.contains("error") || event.status.contains("fail") {
        "✖"
    } else {
        "◆"
    }
}

fn render(frame: &mut ratatui::Frame<'_>, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(1),
        ])
        .split(frame.area());
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(45), Constraint::Percentage(55)])
        .split(chunks[1]);
    render_header(frame, chunks[0], app);
    render_list(frame, body[0], app);
    render_details(frame, body[1], app);
    frame.render_widget(
        Paragraph::new(app.status_line()).style(Style::default().fg(Color::Gray)),
        chunks[2],
    );
}

fn render_header(frame: &mut ratatui::Frame<'_>, area: Rect, app: &App) {
    let title = if app.filter_mode == FilterMode::Input {
        format!("tm-control-mcp monitor  /{}▌", app.filter)
    } else {
        "tm-control-mcp monitor  [q]uit [p]ause [f]ollow [/]filter [e]xport".into()
    };
    frame.render_widget(
        Paragraph::new(title)
            .style(
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            )
            .block(Block::default().borders(Borders::ALL).title("telemetry")),
        area,
    );
}

fn render_list(frame: &mut ratatui::Frame<'_>, area: Rect, app: &mut App) {
    let visible = app.visible_indices();
    let selected = app.selected.min(visible.len().saturating_sub(1));
    app.selected = selected;
    let items: Vec<ListItem> = visible
        .iter()
        .map(|index| {
            let event = &app.events[*index];
            let duration = if event.is_active() {
                format!(
                    "{}ms…",
                    event.elapsed_ms(tm_control_mcp_cli::monitor::now_ms())
                )
            } else {
                format!(
                    "{}ms",
                    event.elapsed_ms(tm_control_mcp_cli::monitor::now_ms())
                )
            };
            let method = event.tool.as_deref().unwrap_or(&event.method);
            ListItem::new(Line::from(vec![
                Span::styled(
                    format!("{} ", icon(app.ascii, event)),
                    Style::default().fg(if event.is_active() {
                        Color::Yellow
                    } else if event.status.contains("error") {
                        Color::Red
                    } else {
                        Color::Green
                    }),
                ),
                Span::raw(format!(
                    "{:<24} {:<12} {}",
                    clip(method, 24),
                    event.status,
                    duration
                )),
            ]))
        })
        .collect();
    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(selected));
    }
    frame.render_stateful_widget(
        List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title(format!("calls ({})", visible.len())),
        ),
        area,
        &mut state,
    );
    let mut scrollbar = ScrollbarState::new(visible.len()).position(selected);
    frame.render_stateful_widget(
        Scrollbar::new(ScrollbarOrientation::VerticalRight),
        area,
        &mut scrollbar,
    );
}

fn render_details(frame: &mut ratatui::Frame<'_>, area: Rect, app: &mut App) {
    let Some(event) = app.selected_event() else {
        frame.render_widget(
            Paragraph::new("No invocation selected")
                .block(Block::default().borders(Borders::ALL).title("details")),
            area,
        );
        return;
    };
    let details = pretty_details(event, app.ascii);
    let max_offset = details
        .height()
        .saturating_sub(area.height.saturating_sub(2) as usize);
    app.details_offset = app.details_offset.min(max_offset);
    frame.render_widget(
        Paragraph::new(details)
            .scroll((app.details_offset as u16, 0))
            .wrap(Wrap { trim: false })
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title("details  [ ] scroll"),
            ),
        area,
    );
}

fn pretty_details(event: &Event, ascii: bool) -> Text<'static> {
    let mut lines = vec![
        Line::from(format!("{} {}", icon(ascii, event), event.invocation_id)),
        Line::from(format!(
            "status: {}    elapsed: {}ms",
            event.status,
            event.elapsed_ms(tm_control_mcp_cli::monitor::now_ms())
        )),
        Line::from(format!(
            "method: {}    tool: {}",
            event.method,
            event.tool.as_deref().unwrap_or("-")
        )),
        Line::from(format!(
            "connection: {}    request: {}",
            event.connection_id, event.request_id
        )),
        Line::from(format!(
            "bytes: args={} result={}",
            event.argument_bytes, event.result_bytes
        )),
        Line::from("arguments:"),
    ];
    lines.extend(json_lines(&event.arguments));
    lines.push(Line::from("result:"));
    lines.extend(json_lines(&event.result));
    lines.truncate(MAX_DETAILS_LINES);
    Text::from(lines)
}

fn json_lines(payload: &str) -> Vec<Line<'static>> {
    match serde_json::from_str::<Value>(payload) {
        Ok(value) => serde_json::to_string_pretty(&value)
            .unwrap_or_else(|_| "<unserializable>".into())
            .lines()
            .map(|line| Line::from(line.to_owned()))
            .collect(),
        Err(_) if payload.is_empty() => vec![Line::from("  <none>")],
        Err(_) => vec![Line::from(format!("  {payload}"))],
    }
}

fn clip(value: &str, width: usize) -> String {
    let mut output: String = value.chars().take(width).collect();
    if output.chars().count() == width && value.chars().count() > width {
        output.pop();
        output.push('…');
    }
    output
}

pub fn export_event(directory: &Path, event: &Event) -> Result<PathBuf> {
    fs::create_dir_all(directory)
        .with_context(|| format!("create export directory {}", directory.display()))?;
    let base = safe_filename(&format!(
        "{}-{}",
        event.invocation_id,
        event.tool.as_deref().unwrap_or("event")
    ));
    let path = directory.join(format!("{base}.json"));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&path)
        .with_context(|| format!("create export {}", path.display()))?;
    serde_json::to_writer_pretty(&mut file, event)?;
    file.write_all(b"\n")?;
    Ok(path)
}

fn safe_filename(value: &str) -> String {
    let mut output = String::new();
    for ch in value.chars() {
        if output.len() >= 96 {
            break;
        }
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            output.push(ch);
        } else {
            output.push('_');
        }
    }
    let output = output.trim_matches('.').trim_matches('_');
    if output.is_empty() {
        "event".into()
    } else {
        output.into()
    }
}

/// A deterministic renderer used by tests and downstream embedders.
#[allow(dead_code)]
pub fn render_test<B: Backend>(terminal: &mut Terminal<B>, app: &mut App) -> io::Result<()> {
    terminal.draw(|frame| render(frame, app)).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    fn event(id: &str, status: &str, tool: &str) -> Arc<Event> {
        Arc::new(Event {
            invocation_id: id.into(),
            connection_id: "c".into(),
            request_id: "r".into(),
            method: "tools/call".into(),
            tool: Some(tool.into()),
            started_ms: 1,
            ended_ms: if status == "started" { 0 } else { 3 },
            status: status.into(),
            argument_bytes: 2,
            result_bytes: 3,
            arguments: "{\"x\":1}".into(),
            result: "{\"ok\":true}".into(),
        })
    }

    #[test]
    fn test_backend_renders_selection_filter_and_details() {
        let mut app = App::new(true, None);
        app.events = vec![
            event("inv/1", "ok", "Echo"),
            event("inv/2", "tool_error", "Fail"),
        ];
        app.stats.events = 2;
        app.filter = "status:error".into();
        let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
        render_test(&mut terminal, &mut app).unwrap();
        let text: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(text.contains("Fail"));
        assert!(!text.contains("Echo"));
        assert!(text.contains("details"));
    }

    #[test]
    fn paused_update_is_a_true_frozen_snapshot() {
        let mut app = App::new(true, None);
        app.events = vec![event("a", "ok", "Echo")];
        app.paused = true;
        let old = app.events[0].clone();
        app.update(
            vec![event("b", "ok", "Other")],
            MonitorStats {
                events: 2,
                ..Default::default()
            },
        );
        assert!(Arc::ptr_eq(&old, &app.events[0]));
        assert_eq!(app.events[0].invocation_id, "a");
    }

    #[test]
    fn filter_input_and_search_modes_are_separate() {
        let mut app = App::new(true, None);
        app.events = vec![event("a", "ok", "Echo"), event("b", "tool_error", "Fail")];
        assert_eq!(
            app.handle_key(KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE)),
            Action::Continue
        );
        assert_eq!(app.filter_mode, FilterMode::Input);
        app.handle_key(KeyEvent::new(KeyCode::Char('e'), KeyModifiers::NONE));
        app.handle_key(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE));
        app.handle_key(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE));
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(app.filter_mode, FilterMode::None);
        assert_eq!(app.visible_indices(), vec![1]);
    }

    #[test]
    fn export_requires_explicit_directory_and_uses_safe_filename() {
        let dir = tempfile::tempdir().unwrap();
        let event = Event {
            invocation_id: "../../private\n".into(),
            connection_id: "c".into(),
            request_id: "r".into(),
            method: "tools/call".into(),
            tool: Some("Take/Secret".into()),
            started_ms: 1,
            ended_ms: 2,
            status: "ok".into(),
            argument_bytes: 1,
            result_bytes: 1,
            arguments: "{\"password\":\"[redacted]\"}".into(),
            result: "{}".into(),
        };
        let path = export_event(dir.path(), &event).unwrap();
        assert_eq!(path.parent(), Some(dir.path()));
        assert!(
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        );
        assert!(std::fs::read_to_string(path).unwrap().contains("password"));
    }
}

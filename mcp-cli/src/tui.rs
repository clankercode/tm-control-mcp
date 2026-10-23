//! Terminal monitor. The model is independent of crossterm so TestBackend tests are deterministic.

use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    net::SocketAddr,
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
    symbols::border,
    text::{Line, Span},
    widgets::{
        Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState,
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

/// Snapshot and interaction state. Selection is reconciled by invocation id, never by ring slot.
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
    http_address: Option<SocketAddr>,
    filter_draft: String,
    selected_id: Option<String>,
    history_start: usize,
    snapshot_ms: u128,
    paused_ms: Option<u128>,
    details_max_offset: usize,
    details_cache: Option<DetailsCache>,
    show_details: bool,
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
            status: String::new(),
            status_until: None,
            stats: MonitorStats::default(),
            http_address: None,
            filter_draft: String::new(),
            selected_id: None,
            history_start: 0,
            snapshot_ms: tm_control_mcp_cli::monitor::now_ms(),
            paused_ms: None,
            details_max_offset: 0,
            details_cache: None,
            show_details: false,
        }
    }

    pub fn set_http_address(&mut self, address: SocketAddr) {
        self.http_address = Some(address);
    }

    pub fn update(&mut self, events: Vec<Arc<Event>>, stats: MonitorStats) {
        if self.paused {
            return;
        }
        let previous = self.selected_event().map(|event| event.invocation_id.clone());
        self.events = events;
        self.stats = stats;
        self.snapshot_ms = tm_control_mcp_cli::monitor::now_ms();
        self.reconcile(previous.as_deref());
    }

    fn query(&self) -> &str {
        if self.filter_mode == FilterMode::Input {
            &self.filter_draft
        } else {
            &self.filter
        }
    }

    pub fn visible_indices(&self) -> Vec<usize> {
        let query = self.query().trim().to_lowercase();
        self.events
            .iter()
            .enumerate()
            .filter_map(|(index, event)| matches_query(event, &query).then_some(index))
            .collect()
    }

    fn selected_event(&self) -> Option<&Event> {
        self.visible_indices()
            .get(self.selected)
            .and_then(|index| self.events.get(*index))
            .map(Arc::as_ref)
    }

    fn reconcile(&mut self, previous: Option<&str>) {
        let visible = self.visible_indices();
        self.selected = if self.follow && self.filter_mode != FilterMode::Input {
            visible.len().saturating_sub(1)
        } else {
            previous
                .and_then(|id| visible.iter().position(|i| self.events[*i].invocation_id == id))
                .unwrap_or_else(|| self.selected.min(visible.len().saturating_sub(1)))
        };
        self.sync_selection(&visible);
    }

    fn sync_selection(&mut self, visible: &[usize]) {
        self.selected = self.selected.min(visible.len().saturating_sub(1));
        let id = visible.get(self.selected).map(|i| self.events[*i].invocation_id.clone());
        if self.selected_id != id {
            self.details_offset = 0;
            self.details_max_offset = 0;
            self.details_cache = None;
            self.selected_id = id;
        }
        self.history_start = self.history_start.min(visible.len().saturating_sub(1));
    }

    fn display_ms(&self) -> u128 {
        if self.paused {
            self.paused_ms.unwrap_or(self.snapshot_ms)
        } else {
            tm_control_mcp_cli::monitor::now_ms()
        }
    }

    fn notice(&mut self, text: impl Into<String>) {
        self.status = text.into();
        self.status_until = Some(Instant::now() + Duration::from_secs(5));
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Action {
        if key.kind != KeyEventKind::Press {
            return Action::Continue;
        }
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            return Action::Quit;
        }
        if self.filter_mode == FilterMode::Input {
            let previous = self.selected_event().map(|event| event.invocation_id.clone());
            match key.code {
                KeyCode::Esc => self.filter_mode = FilterMode::None,
                KeyCode::Enter => {
                    self.filter = self.filter_draft.clone();
                    self.filter_mode = FilterMode::None;
                }
                KeyCode::Backspace => { self.filter_draft.pop(); }
                KeyCode::Char(ch) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.filter_draft.push(ch);
                }
                _ => {}
            }
            // Preview the draft without a following stream moving the selection while typing.
            self.reconcile(previous.as_deref());
            return Action::Continue;
        }
        let previous = self.selected_event().map(|event| event.invocation_id.clone());
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => return Action::Quit,
            KeyCode::Char('p') | KeyCode::Char(' ') => {
                if self.paused {
                    self.paused = false;
                    self.paused_ms = None;
                } else {
                    self.paused_ms = Some(self.display_ms());
                    self.paused = true;
                }
            }
            KeyCode::Char('f') => {
                self.follow = !self.follow;
                self.reconcile(previous.as_deref());
            }
            KeyCode::Char('/') => {
                self.filter_draft = self.filter.clone();
                self.filter_mode = FilterMode::Input;
            }
            KeyCode::Char('c') => {
                self.filter.clear();
                self.reconcile(previous.as_deref());
            }
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(1),
            KeyCode::PageUp => self.move_selection(-10),
            KeyCode::PageDown => self.move_selection(10),
            KeyCode::Home => self.move_selection(isize::MIN),
            KeyCode::End => self.move_selection(isize::MAX),
            KeyCode::Tab => self.show_details = !self.show_details,
            KeyCode::Char('[') => self.details_offset = self.details_offset.saturating_sub(5),
            KeyCode::Char(']') => {
                self.details_offset = self.details_offset.saturating_add(5).min(self.details_max_offset);
            }
            KeyCode::Char('e') => self.export_selected(),
            _ => {}
        }
        Action::Continue
    }

    fn move_selection(&mut self, amount: isize) {
        self.follow = false;
        self.selected = self.selected.saturating_add_signed(amount);
        self.sync_selection(&self.visible_indices());
    }

    fn export_selected(&mut self) {
        let Some(event) = self.selected_event().cloned() else {
            self.notice("Nothing selected to export");
            return;
        };
        let Some(dir) = self.export_dir.clone() else {
            self.notice("Export disabled; start with --export-dir PATH");
            return;
        };
        match export_event(&dir, &event) {
            Ok(path) => self.notice(format!("Payload exported: {}", path.display())),
            Err(error) => self.notice(format!("Export failed: {error}")),
        }
    }
}

fn matches_query(event: &Event, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    if let Some(value) = query.strip_prefix("status:") {
        return event.status.to_lowercase().contains(value.trim());
    }
    if let Some(value) = query.strip_prefix("tool:") {
        return event.tool.as_deref().unwrap_or("").to_lowercase().contains(value.trim());
    }
    if query == "error" || query == "errors" {
        return matches!(outcome(event), Outcome::Error | Outcome::Unavailable | Outcome::Invalid);
    }
    [event.method.as_str(), event.tool.as_deref().unwrap_or(""), event.status.as_str(),
        event.connection_id.as_str(), event.request_id.as_str()]
        .iter().any(|value| value.to_lowercase().contains(query))
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
    http_address: SocketAddr,
) -> Result<()> {
    let terminal = TerminalGuard::enter().context("enter terminal monitor")?;
    let result = tokio::task::spawn_blocking(move || {
        draw_loop(core, cancellation.clone(), terminal, ascii, export_dir, http_address)
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
    http_address: SocketAddr,
) -> Result<()> {
    let mut app = App::new(ascii, export_dir);
    app.set_http_address(http_address);
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

// One palette and outcome classifier are shared by history, metadata, cards and chrome.
mod theme {
    use ratatui::style::Color;
    pub const BASE: Color = Color::Rgb(9, 16, 26);
    pub const PANEL: Color = Color::Rgb(13, 23, 36);
    pub const CHROME: Color = Color::Rgb(17, 30, 46);
    pub const CARD: Color = Color::Rgb(8, 18, 30);
    pub const TEXT: Color = Color::Rgb(219, 230, 242);
    pub const MUTED: Color = Color::Rgb(147, 168, 191);
    pub const BORDER: Color = Color::Rgb(43, 63, 84);
    pub const CYAN: Color = Color::Rgb(97, 215, 246);
    pub const GREEN: Color = Color::Rgb(82, 219, 160);
    pub const AMBER: Color = Color::Rgb(255, 208, 121);
    pub const ROSE: Color = Color::Rgb(255, 115, 141);
    pub const VIOLET: Color = Color::Rgb(201, 176, 255);
    pub const SELECTED: Color = Color::Rgb(23, 52, 71);
    pub const ERROR_SELECTED: Color = Color::Rgb(57, 29, 44);
    pub const ERROR_CARD: Color = Color::Rgb(35, 21, 33);
    pub const ERROR_BORDER: Color = Color::Rgb(136, 65, 89);
    pub const SCROLL: Color = Color::Rgb(78, 111, 135);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome { Active, Success, Error, Invalid, Unavailable, Cancelled, Other }

fn outcome(event: &Event) -> Outcome {
    if event.is_active() {
        Outcome::Active
    } else if event.status == "ok" {
        Outcome::Success
    } else if event.status == "cancelled" {
        Outcome::Cancelled
    } else if event.status.contains("unavailable") || event.status == "queue_full" {
        Outcome::Unavailable
    } else if matches!(event.status.as_str(), "invalid_arguments" | "unknown_tool") {
        Outcome::Invalid
    } else if event.status.contains("error") || event.status.contains("fail") {
        Outcome::Error
    } else {
        Outcome::Other
    }
}

impl Outcome {
    fn color(self) -> Color {
        match self {
            Self::Active | Self::Unavailable => theme::AMBER,
            Self::Success => theme::GREEN,
            Self::Error => theme::ROSE,
            Self::Invalid => theme::VIOLET,
            Self::Cancelled | Self::Other => theme::MUTED,
        }
    }

    fn is_failure(self) -> bool {
        matches!(self, Self::Error | Self::Invalid | Self::Unavailable)
    }

    fn icon(self, ascii: bool) -> &'static str {
        match (self, ascii) {
            (Self::Active, true) => "~",
            (Self::Active, false) => "◌",
            (Self::Success, true) => "+",
            (Self::Success, false) => "◆",
            (Self::Error, true) => "x",
            (Self::Error, false) => "✖",
            (Self::Invalid, _) => "!",
            (Self::Unavailable, _) => "?",
            (Self::Cancelled, _) => "-",
            (Self::Other, _) => ".",
        }
    }
}

fn fg(color: Color) -> Style { Style::default().fg(color) }
fn bold(color: Color) -> Style { fg(color).add_modifier(Modifier::BOLD) }

fn border_set(ascii: bool) -> border::Set {
    if ascii {
        border::Set {
            top_left: "+", top_right: "+", bottom_left: "+", bottom_right: "+",
            vertical_left: "|", vertical_right: "|", horizontal_top: "-", horizontal_bottom: "-",
        }
    } else {
        border::ROUNDED
    }
}

fn panel(title: impl Into<Line<'static>>, ascii: bool, background: Color) -> Block<'static> {
    Block::default().borders(Borders::ALL).border_set(border_set(ascii))
        .border_style(fg(theme::BORDER)).title(title)
        .title_style(bold(theme::MUTED)).style(fg(theme::TEXT).bg(background))
}

fn inset(area: Rect, horizontal: u16, vertical: u16) -> Rect {
    Rect::new(area.x.saturating_add(horizontal.min(area.width)),
        area.y.saturating_add(vertical.min(area.height)),
        area.width.saturating_sub(horizontal.saturating_mul(2)),
        area.height.saturating_sub(vertical.saturating_mul(2)))
}

fn put(frame: &mut ratatui::Frame<'_>, area: Rect, line: Line<'_>) {
    if area.width > 0 && area.height > 0 {
        frame.render_widget(Paragraph::new(line), Rect::new(area.x, area.y, area.width, 1));
    }
}

fn row(area: Rect, y: u16) -> Rect {
    Rect::new(area.x, area.y.saturating_add(y), area.width, u16::from(y < area.height))
}

fn render(frame: &mut ratatui::Frame<'_>, app: &mut App) {
    let area = frame.area();
    frame.render_widget(Block::default().style(fg(theme::TEXT).bg(theme::BASE)), area);
    if area.width == 0 || area.height == 0 { return; }
    let visible = app.visible_indices();
    app.sync_selection(&visible);
    if app.status_until.is_some_and(|until| Instant::now() >= until) {
        app.status.clear();
        app.status_until = None;
    }
    let now = app.display_ms();
    if area.width < 40 || area.height < 10 {
        render_tiny(frame, area, app, &visible, now);
        return;
    }
    let compact = area.height < 20 || area.width < 60;
    let chunks = Layout::default().direction(Direction::Vertical).constraints([
        Constraint::Length(if compact { 3 } else { 5 }),
        Constraint::Min(3), Constraint::Length(3),
    ]).split(area);
    render_header(frame, chunks[0], app, visible.len());
    if area.width >= 100 {
        let panes = Layout::default().direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(44), Constraint::Percentage(56)]).split(chunks[1]);
        render_list(frame, panes[0], app, &visible, now);
        render_details(frame, panes[1], app, &visible, now);
    } else if app.show_details {
        render_details(frame, chunks[1], app, &visible, now);
    } else {
        render_list(frame, chunks[1], app, &visible, now);
    }
    render_footer(frame, chunks[2], app, &visible);
}

fn mode_line(app: &App) -> Line<'static> {
    Line::from(vec![
        Span::styled(if app.paused { "PAUSED" } else { "LIVE" },
            bold(if app.paused { theme::AMBER } else { theme::CYAN })),
        Span::styled(if app.follow { "  FOLLOW newest" } else { "  HISTORY / follow off" }, fg(theme::MUTED)),
        Span::styled(if app.filter_mode == FilterMode::Input { "  DRAFT" } else { "" }, fg(theme::AMBER)),
    ])
}

fn endpoint(app: &App) -> String {
    app.http_address.map(|address| format!("HTTP {address}/mcp"))
        .unwrap_or_else(|| "HTTP address not supplied".into())
}

fn filter_line(app: &App, matches: usize, width: usize) -> Line<'static> {
    let suffix = format!("  {matches} matching / {} hidden", app.events.len().saturating_sub(matches));
    let label = if app.filter_mode == FilterMode::Input { "Draft /" } else { "Filter /" };
    let query = if app.query().is_empty() { "all" } else { app.query() };
    let cursor = if app.filter_mode == FilterMode::Input { if app.ascii { "_" } else { "▏" } } else { "" };
    let available = width.saturating_sub(Span::raw(label).width() + Span::raw(&suffix).width() + Span::raw(cursor).width());
    Line::from(vec![Span::styled(label, fg(theme::MUTED)),
        Span::styled(clip_cells(query, available, app.ascii), fg(theme::CYAN)),
        Span::styled(cursor, fg(theme::CYAN)), Span::styled(suffix, fg(theme::MUTED))])
}

fn render_header(frame: &mut ratatui::Frame<'_>, area: Rect, app: &App, matches: usize) {
    frame.render_widget(Block::default().borders(Borders::BOTTOM).border_set(border_set(app.ascii))
        .border_style(fg(theme::BORDER)).style(fg(theme::TEXT).bg(theme::CHROME)), area);
    let inner = inset(Rect::new(area.x, area.y, area.width, area.height.saturating_sub(1)), 1, 0);
    if area.height <= 3 {
        let mode = Line::styled(format!("{} {}", if app.paused { "PAUSED" } else { "LIVE" },
            if app.follow { "F" } else { "H" }), bold(if app.paused { theme::AMBER } else { theme::CYAN }));
        put(frame, row(inner, 0), pair(mode, Line::styled(endpoint(app), fg(theme::MUTED)), inner.width as usize));
        put(frame, row(inner, 1), filter_line(app, matches, inner.width as usize));
        return;
    }
    put(frame, row(inner, 0), pair(Line::styled("tm-control-mcp monitor", bold(theme::TEXT)),
        Line::styled(endpoint(app), fg(theme::MUTED)), inner.width as usize));
    put(frame, row(inner, 1), Line::styled("TM CONTROL MCP / TELEMETRY", fg(theme::MUTED)));
    let hints = if app.filter_mode == FilterMode::Input {
        "[Enter] apply  [Esc] cancel"
    } else if area.width < 100 {
        if app.show_details { "[Tab] calls  [ ] scroll  [q] quit" } else { "[Tab] details  [/] filter  [q] quit" }
    } else { "[q] quit  [p] pause  [f] follow  [/] filter  [e] export" };
    put(frame, row(inner, 2), pair(mode_line(app), Line::styled(hints, fg(theme::MUTED)), inner.width as usize));
    put(frame, row(inner, 3), filter_line(app, matches, inner.width as usize));
}

fn render_footer(frame: &mut ratatui::Frame<'_>, area: Rect, app: &App, visible: &[usize]) {
    frame.render_widget(Block::default().borders(Borders::TOP).border_set(border_set(app.ascii))
        .border_style(fg(theme::BORDER)).style(fg(theme::MUTED).bg(theme::CHROME)), area);
    let inner = inset(Rect::new(area.x, area.y.saturating_add(1), area.width, area.height.saturating_sub(1)), 1, 0);
    let stats = if inner.width < 58 {
        format!("store {}/{} a{} ev{} drop{} lag{} log{}/{}", app.events.len(),
            tm_control_mcp_cli::monitor::MAX_EVENTS, app.stats.active, app.stats.evicted,
            app.stats.dropped, app.stats.lagged, app.stats.jsonl_dropped, app.stats.jsonl_errors)
    } else { format!("events {}/{}  active {}  evicted {}  drops {}  lag {}  log {}/{}",
        app.events.len(), tm_control_mcp_cli::monitor::MAX_EVENTS, app.stats.active, app.stats.evicted,
        app.stats.dropped, app.stats.lagged, app.stats.jsonl_dropped, app.stats.jsonl_errors) };
    let memory = format!("{} KiB retained", app.stats.retained_bytes / 1024);
    put(frame, row(inner, 0), pair(Line::styled(stats, fg(theme::MUTED)),
        if inner.width >= 110 { Line::styled(memory, fg(theme::MUTED)) } else { Line::default() }, inner.width as usize));
    let message = if !app.status.is_empty() {
        app.status.clone()
    } else if app.filter_mode == FilterMode::Input {
        "Editing draft: status:error, tool:name, errors, or text | Enter apply / Esc cancel".into()
    } else if inner.width < 98 {
        format!("[Tab] {}  [p] {}  [f] follow  [c] clear  [ ] scroll  [q] quit",
            if app.show_details { "calls" } else { "details" }, if app.paused { "resume" } else { "pause" })
    } else if app.paused {
        "Snapshot frozen (including elapsed time and counters) | [p] resume | [c] clear filter".into()
    } else if visible.is_empty() {
        if app.events.is_empty() { "No invocations observed | LIVE is the monitor refresh mode".into() }
        else { "No matching invocations | [c] clear filter".into() }
    } else {
        format!("[Up/Down] select  [PgUp/PgDn] history  [ ] details  [c] clear | export {}",
            if app.export_dir.is_some() { "[e]" } else { "disabled (--export-dir)" })
    };
    put(frame, row(inner, 1), Line::styled(clip_cells(&message, inner.width as usize, app.ascii), fg(theme::MUTED)));
}

fn render_tiny(frame: &mut ratatui::Frame<'_>, area: Rect, app: &App, visible: &[usize], now: u128) {
    put(frame, row(area, 0), mode_line(app));
    put(frame, row(area, 1), Line::styled(endpoint(app), fg(theme::MUTED)));
    put(frame, row(area, 2), filter_line(app, visible.len(), area.width as usize));
    if let Some(index) = visible.get(app.selected) {
        let event = &app.events[*index];
        put(frame, row(area, 3), Line::styled(format!("{} {}", outcome(event).icon(app.ascii), event.tool.as_deref().unwrap_or(&event.method)), bold(outcome(event).color())));
        put(frame, row(area, 4), Line::styled(format!("{} {} | {}/{}", event.status, duration(event, now), app.selected + 1, visible.len()), fg(theme::TEXT)));
    }
    put(frame, row(area, 5), Line::styled("Resize | p pause / filter q quit", fg(theme::MUTED)));
}

#[derive(Clone, Copy)]
struct Columns { name: usize, status: usize, time: usize, compact: bool }

impl Columns {
    fn new(width: usize) -> Self {
        if width < 48 {
            Self { name: width.saturating_sub(4), status: 0, time: 9, compact: true }
        } else {
            Self { name: width.saturating_sub(30), status: 13, time: 9, compact: false }
        }
    }
}

fn tool_lines(event: &Event, width: usize, limit: usize) -> Vec<Line<'static>> {
    let name = event.tool.as_deref().unwrap_or(&event.method);
    // Prefer the pack boundary: the function suffix stays intact whenever it fits a line.
    if Span::raw(name).width() > width {
        if let Some((pack, tool)) = name.rsplit_once('.') {
            let mut lines = wrap_cells(&Line::raw(format!("{pack}.")), width, limit);
            lines.extend(wrap_cells(&Line::raw(tool.to_owned()), width, limit));
            return lines;
        }
    }
    wrap_cells(&Line::raw(name.to_owned()), width, limit)
}

fn render_list(frame: &mut ratatui::Frame<'_>, area: Rect, app: &mut App, visible: &[usize], now: u128) {
    let position = if visible.is_empty() { 0 } else { app.selected + 1 };
    let title = format!(" CALL HISTORY  {position}/{} ", visible.len());
    let block = panel(title, app.ascii, theme::PANEL);
    let inner = inset(block.inner(area), 1, 0);
    frame.render_widget(block, area);
    if inner.width < 5 || inner.height == 0 { return; }
    let content = Rect::new(inner.x, inner.y, inner.width.saturating_sub(1), inner.height);
    let columns = Columns::new(content.width as usize);
    let heading = if columns.compact { Line::styled("    TOOL / STATUS / ELAPSED", fg(theme::MUTED)) }
        else { Line::from(vec![Span::raw("    "), Span::styled(pad("TOOL", columns.name, false), fg(theme::MUTED)),
            Span::raw("  "), Span::styled(pad("STATUS", columns.status, false), fg(theme::MUTED)),
            Span::raw(" "), Span::styled(pad("ELAPSED", columns.time, true), fg(theme::MUTED))]) };
    put(frame, row(content, 0), heading);
    let rows = Rect::new(content.x, content.y.saturating_add(1), content.width, content.height.saturating_sub(1));
    if visible.is_empty() {
        let message = if app.events.is_empty() { "No invocations observed" } else { "No matches. [c] clear filter" };
        put(frame, row(rows, 1.min(rows.height.saturating_sub(1))), Line::styled(message, fg(theme::MUTED)));
        return;
    }
    if rows.height == 0 { return; }
    // Keep a stable viewport across ticks; only move it when selection would leave the pane.
    app.history_start = app.history_start.min(app.selected);
    let events = &app.events;
    let row_height = |index: usize| {
        let n = tool_lines(&events[visible[index]], columns.name.max(1), 128).len();
        (n + if columns.compact { 1 } else { 0 } + 1).max(2).min(rows.height as usize)
    };
    let mut used: usize = (app.history_start..=app.selected).map(row_height).sum();
    while used > rows.height as usize && app.history_start < app.selected {
        used = used.saturating_sub(row_height(app.history_start));
        app.history_start += 1;
    }
    let mut y = 0;
    let mut shown = 0;
    for (position, index) in visible.iter().enumerate().skip(app.history_start) {
        let height = row_height(position);
        if y + height > rows.height as usize { break; }
        let event = &app.events[*index];
        let selected = position == app.selected;
        let state = outcome(event);
        let accent = if selected { if state.is_failure() { theme::ROSE } else { theme::CYAN } } else { theme::PANEL };
        let background = if selected { if state.is_failure() { theme::ERROR_SELECTED } else { theme::SELECTED } } else { theme::PANEL };
        let row_area = Rect::new(rows.x, rows.y.saturating_add(y as u16), rows.width, height as u16);
        frame.render_widget(Block::default().style(fg(theme::TEXT).bg(background)), row_area);
        let mut names = tool_lines(event, columns.name.max(1), 128);
        let capacity = height.saturating_sub(if columns.compact { 1 } else { 0 }).max(1);
        if names.len() > capacity {
            // Extremely long names in a short viewport still retain the function suffix.
            names = names.split_off(names.len() - capacity);
        }
        for line_index in 0..height {
            let marker = if selected { if app.ascii { ">" } else { "▎" } } else { " " };
            let mut spans = vec![Span::styled(marker, bold(accent)), Span::raw(" ")];
            if line_index < names.len() {
                spans.push(Span::styled(if line_index == 0 { state.icon(app.ascii) } else { " " }, fg(state.color())));
                spans.push(Span::raw(" "));
                spans.push(Span::styled(pad(&line_string(&names[line_index]), columns.name, false),
                    if selected { bold(theme::TEXT) } else { fg(theme::TEXT) }));
                if !columns.compact {
                    spans.push(Span::raw("  "));
                    spans.push(Span::styled(if line_index == 0 { pad(&clip_cells(&event.status, columns.status, app.ascii), columns.status, false) } else { " ".repeat(columns.status) }, fg(state.color())));
                    spans.push(Span::raw(" "));
                    spans.push(Span::styled(if line_index == 0 { pad(&duration(event, now), columns.time, true) } else { " ".repeat(columns.time) }, fg(theme::MUTED)));
                }
            } else if columns.compact && line_index == names.len() {
                spans.push(Span::raw("  "));
                spans.push(Span::styled(event.status.clone(), fg(state.color())));
                let occupied = 4 + Span::raw(&event.status).width() + Span::raw(duration(event, now)).width();
                spans.push(Span::raw(" ".repeat((rows.width as usize).saturating_sub(occupied))));
                spans.push(Span::styled(duration(event, now), fg(theme::MUTED)));
            }
            put(frame, row(row_area, line_index as u16), Line::from(spans).style(fg(theme::TEXT).bg(background)));
        }
        y += height;
        shown += 1;
    }
    if app.history_start > 0 || app.history_start + shown < visible.len() {
        render_scrollbar(frame, Rect::new(inner.right().saturating_sub(1), rows.y, 1, rows.height),
            visible.len(), app.history_start, shown, app.ascii);
    }
}

fn duration(event: &Event, now: u128) -> String {
    let elapsed = event.elapsed_ms(now);
    let text = if elapsed < 1000 { format!("{elapsed}ms") }
        else if elapsed < 60_000 { format!("{}.{:02}s", elapsed / 1000, (elapsed % 1000) / 10) }
        else { format!("{}m{:02}s", elapsed / 60_000, (elapsed / 1000) % 60) };
    if event.is_active() { format!("{text}+") } else { text }
}

fn render_scrollbar(frame: &mut ratatui::Frame<'_>, area: Rect, length: usize, offset: usize, viewport: usize, ascii: bool) {
    if area.height == 0 || length <= viewport { return; }
    let mut state = ScrollbarState::new(length).position(offset).viewport_content_length(viewport);
    frame.render_stateful_widget(Scrollbar::new(ScrollbarOrientation::VerticalRight)
        .begin_symbol(None).end_symbol(None).track_symbol(Some(if ascii { "|" } else { "│" }))
        .thumb_symbol(if ascii { "#" } else { "┃" }).track_style(fg(theme::BORDER))
        .thumb_style(fg(theme::SCROLL)), area, &mut state);
}

#[derive(Debug)]
struct DetailsCache {
    event: Arc<Event>,
    width: usize,
    ascii: bool,
    lines: Vec<Line<'static>>,
}

fn render_details(frame: &mut ratatui::Frame<'_>, area: Rect, app: &mut App, visible: &[usize], now: u128) {
    let Some(event) = visible.get(app.selected).map(|index| app.events[*index].clone()) else {
        frame.render_widget(Paragraph::new(if app.events.is_empty() { "No invocation selected" } else { "No matching invocation" })
            .style(fg(theme::MUTED)).block(panel(" DETAILS ", app.ascii, theme::BASE)), area);
        app.details_offset = 0;
        app.details_max_offset = 0;
        return;
    };
    let block = panel(" DETAILS ", app.ascii, theme::BASE);
    let inner = inset(block.inner(area), 1, 0);
    frame.render_widget(block, area);
    if inner.width < 8 || inner.height < 2 { return; }
    let width = inner.width.saturating_sub(1) as usize;
    let state = outcome(&event);
    put(frame, row(inner, 0), pair(Line::from(vec![Span::styled(format!("{} ", state.icon(app.ascii)), fg(state.color())),
        Span::styled(clip_cells(&event.invocation_id, width.saturating_sub(18), app.ascii), bold(theme::TEXT))]),
        Line::styled(duration(&event, now), fg(theme::MUTED)), width));
    let status = Line::from(vec![Span::styled("status  ", fg(theme::MUTED)), Span::styled(event.status.clone(), bold(state.color()))]);
    put(frame, row(inner, 1), status);
    let viewport = Rect::new(inner.x, inner.y.saturating_add(2), width as u16, inner.height.saturating_sub(2));
    if viewport.height == 0 { return; }
    if app.details_cache.as_ref().is_none_or(|cache| !Arc::ptr_eq(&cache.event, &event) || cache.width != width || cache.ascii != app.ascii) {
        app.details_cache = Some(DetailsCache { lines: detail_lines(&event, width, app.ascii), event: event.clone(), width, ascii: app.ascii });
    }
    let cache = app.details_cache.as_ref().expect("details layout cached");
    app.details_max_offset = cache.lines.len().saturating_sub(viewport.height as usize);
    app.details_offset = app.details_offset.min(app.details_max_offset);
    // These are already wrapped terminal lines. Never ask Paragraph to rewrap or use a u16 scroll offset.
    for (y, line) in cache.lines.iter().skip(app.details_offset).take(viewport.height as usize).enumerate() {
        put(frame, row(viewport, y as u16), line.clone());
    }
    let hint = if app.details_max_offset == 0 { " [ ] scroll ".into() }
        else { format!(" [ ] {}/{} ", app.details_offset + 1, app.details_max_offset + 1) };
    let hint_width = Span::raw(&hint).width().min(area.width.saturating_sub(12) as usize) as u16;
    put(frame, Rect::new(area.right().saturating_sub(hint_width + 1), area.y, hint_width, 1), Line::styled(hint, fg(theme::MUTED)));
    render_scrollbar(frame, Rect::new(inner.right().saturating_sub(1), viewport.y, 1, viewport.height),
        cache.lines.len(), app.details_offset, viewport.height as usize, app.ascii);
}

fn detail_lines(event: &Event, width: usize, ascii: bool) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    for (label, value) in [
        ("method", event.method.clone()),
        ("tool", event.tool.clone().unwrap_or_else(|| "-".into())),
        ("connection", event.connection_id.clone()),
        ("request", event.request_id.clone()),
        ("bytes", format!("args={}  result={}", event.argument_bytes, event.result_bytes)),
    ] {
        lines.extend(wrap_cells(&Line::from(vec![Span::styled(format!("{label}  "), fg(theme::MUTED)),
            Span::styled(value, fg(theme::TEXT))]), width, 128));
    }
    lines.push(Line::default());
    // Each payload owns a budget: huge arguments cannot starve the result envelope.
    let budget = (MAX_DETAILS_LINES.saturating_sub(lines.len() + 2)) / 2;
    append_card(&mut lines, "ARGUMENTS", &event.arguments, width, ascii, false, false, budget);
    lines.push(Line::default());
    append_card(&mut lines, "RESULT", &event.result, width, ascii, outcome(event).is_failure(), event.is_active(), budget);
    lines
}

fn append_card(output: &mut Vec<Line<'static>>, title: &str, payload: &str, width: usize, ascii: bool, error: bool, waiting: bool, budget: usize) {
    if width < 5 { return; }
    let background = if error { theme::ERROR_CARD } else { theme::CARD };
    let edge = if error { theme::ERROR_BORDER } else { theme::BORDER };
    let borders = border_set(ascii);
    let cap = width.saturating_sub(4);
    let mut body = Vec::new();
    let source = if payload.is_empty() {
        if waiting { "Waiting for result...".into() } else { "<none>".into() }
    } else {
        serde_json::from_str::<Value>(payload).ok().and_then(|value| serde_json::to_string_pretty(&value).ok())
            .unwrap_or_else(|| tm_control_mcp_cli::monitor::clean_text(payload, tm_control_mcp_cli::monitor::MAX_EVENT_COPY))
    };
    let body_budget = budget.saturating_sub(3).max(1);
    let mut truncated = false;
    for raw in source.lines() {
        // One extra line is sufficient to distinguish a complete budget from truncation.
        let wrapped = wrap_cells(&json_line(raw, error), cap, body_budget.saturating_sub(body.len()) + 1);
        for line in wrapped {
            if body.len() == body_budget { truncated = true; break; }
            body.push(line);
        }
        if truncated { break; }
    }
    if truncated {
        body.pop();
        body.push(Line::styled(clip_cells("[display truncated; export full retained payload]", cap, ascii), fg(theme::AMBER)));
    }
    let title = format!(" {title}{} ", if error { " / ERROR" } else { "" });
    let title = clip_cells(&title, width.saturating_sub(2), ascii);
    output.push(Line::from(vec![Span::raw(borders.top_left), Span::styled(title.clone(), bold(if error { theme::ROSE } else { theme::MUTED })),
        Span::raw(borders.horizontal_top.repeat(width.saturating_sub(2 + Span::raw(title).width()))), Span::raw(borders.top_right)]).style(fg(edge).bg(background)));
    for line in body {
        let padding = cap.saturating_sub(line.width());
        let mut spans = vec![Span::styled(borders.vertical_left, fg(edge)), Span::raw(" ")];
        spans.extend(line.spans);
        spans.push(Span::raw(" ".repeat(padding + 1)));
        spans.push(Span::styled(borders.vertical_right, fg(edge)));
        output.push(Line::from(spans).style(fg(theme::TEXT).bg(background)));
    }
    output.push(Line::from(format!("{}{}{}", borders.bottom_left, borders.horizontal_bottom.repeat(width.saturating_sub(2)), borders.bottom_right)).style(fg(edge).bg(background)));
}

/// Lex only for presentation. The retained JSON and exported native envelope stay untouched.
fn json_line(raw: &str, error: bool) -> Line<'static> {
    let bytes = raw.as_bytes();
    let mut spans = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        let start = index;
        let color = match bytes[index] {
            b'"' => {
                index += 1;
                while index < bytes.len() {
                    match bytes[index] {
                        b'\\' => index = (index + 2).min(bytes.len()),
                        b'"' => { index += 1; break; }
                        _ => index += 1,
                    }
                }
                if raw[index..].trim_start().starts_with(':') { theme::CYAN }
                else if error { Color::Rgb(255, 183, 196) } else { theme::GREEN }
            }
            b'0'..=b'9' | b'-' => {
                index += 1;
                while index < bytes.len() && matches!(bytes[index], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-') { index += 1; }
                theme::CYAN
            }
            b't' | b'f' | b'n' => {
                index += 1;
                while index < bytes.len() && bytes[index].is_ascii_alphabetic() { index += 1; }
                theme::AMBER
            }
            _ => {
                index += raw[index..].chars().next().map_or(1, char::len_utf8);
                theme::MUTED
            }
        };
        push_span(&mut spans, &raw[start..index], fg(color));
    }
    Line::from(spans)
}

fn push_span(spans: &mut Vec<Span<'static>>, text: &str, style: Style) {
    if let Some(last) = spans.last_mut().filter(|span| span.style == style) {
        last.content.to_mut().push_str(text);
    } else {
        spans.push(Span::styled(text.to_owned(), style));
    }
}

/// Hard wrap by grapheme and terminal cell width, preserving token styles and indentation.
/// The explicit limit bounds both storage and work even for a single pathological JSON string.
fn wrap_cells(line: &Line<'_>, width: usize, limit: usize) -> Vec<Line<'static>> {
    if width == 0 || limit == 0 { return Vec::new(); }
    let mut lines = Vec::new();
    let mut spans = Vec::new();
    let mut used = 0;
    for grapheme in line.styled_graphemes(Style::default()) {
        let cells = Span::raw(grapheme.symbol).width();
        if used + cells > width && used > 0 {
            lines.push(Line::from(std::mem::take(&mut spans)));
            if lines.len() == limit { return lines; }
            used = 0;
        }
        if cells > width {
            push_span(&mut spans, "?", grapheme.style);
            used += 1;
        } else {
            push_span(&mut spans, grapheme.symbol, grapheme.style);
            used += cells;
        }
    }
    if !spans.is_empty() || lines.is_empty() { lines.push(Line::from(spans)); }
    lines
}

fn line_string(line: &Line<'_>) -> String {
    line.spans.iter().map(|span| span.content.as_ref()).collect()
}

fn clip_cells(value: &str, width: usize, ascii: bool) -> String {
    let span = Span::raw(value);
    if span.width() <= width { return value.to_owned(); }
    let marker = if ascii { ".".repeat(width.min(3)) } else if width > 0 { "…".into() } else { String::new() };
    let cap = width.saturating_sub(Span::raw(&marker).width());
    let mut output = String::new();
    let mut used = 0;
    for grapheme in span.styled_graphemes(Style::default()) {
        let cells = Span::raw(grapheme.symbol).width();
        if used + cells > cap { break; }
        output.push_str(grapheme.symbol);
        used += cells;
    }
    output.push_str(&marker);
    output
}

fn pad(value: &str, width: usize, right: bool) -> String {
    let padding = " ".repeat(width.saturating_sub(Span::raw(value).width()));
    if right { format!("{padding}{value}") } else { format!("{value}{padding}") }
}

fn pair(mut left: Line<'static>, right: Line<'static>, width: usize) -> Line<'static> {
    let occupied = left.width() + right.width();
    if occupied <= width {
        left.spans.push(Span::raw(" ".repeat(width - occupied)));
        left.spans.extend(right.spans);
    }
    left
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
    use ratatui::{backend::TestBackend, buffer::Buffer};

    fn event(id: &str, status: &str, tool: &str) -> Arc<Event> {
        Arc::new(Event {
            invocation_id: id.into(), connection_id: "conn-42".into(), request_id: "84".into(),
            method: "tools/call".into(), tool: Some(tool.into()),
            started_ms: if status == "started" { tm_control_mcp_cli::monitor::now_ms().saturating_sub(294) } else { 100 },
            ended_ms: if status == "started" { 0 } else { 5140 }, status: status.into(),
            argument_bytes: 25, result_bytes: if status == "started" { 0 } else { 11 },
            arguments: "{\"blocks\":true,\"maxRows\":24}".into(),
            result: if status == "started" { String::new() } else { "{\"ok\":true}".into() },
        })
    }

    fn app(events: Vec<Arc<Event>>, ascii: bool) -> App {
        let mut app = App::new(ascii, None);
        app.set_http_address("127.0.0.1:47123".parse().unwrap());
        let stats = MonitorStats { events: events.len(), active: events.iter().filter(|e| e.is_active()).count(), ..Default::default() };
        app.update(events, stats);
        app
    }

    fn press(app: &mut App, code: KeyCode) -> Action {
        app.handle_key(KeyEvent::new(code, KeyModifiers::NONE))
    }

    fn draw(app: &mut App, width: u16, height: u16) -> Buffer {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        render_test(&mut terminal, app).unwrap();
        terminal.backend().buffer().clone()
    }

    fn rows(buffer: &Buffer) -> Vec<String> {
        if buffer.area.width == 0 { return Vec::new(); }
        buffer.content().chunks(buffer.area.width as usize)
            .map(|row| row.iter().map(|cell| cell.symbol()).collect()).collect()
    }

    fn text(buffer: &Buffer) -> String { rows(buffer).join("\n") }

    #[test]
    fn selected_wrapped_rows_have_background_and_an_independent_accent_including_errors() {
        for (status, background, accent) in [("ok", theme::SELECTED, theme::CYAN),
            ("tool_error", theme::ERROR_SELECTED, theme::ROSE)] {
            let mut app = app(vec![event("inv-7", status, "tm-mcp-pack-epp.VeryLongFunctionSuffix")], false);
            let buffer = draw(&mut app, 120, 36);
            let marked: Vec<_> = buffer.content().iter().enumerate().filter(|(_, cell)| cell.symbol() == "▎").collect();
            assert!(marked.len() >= 2, "the whole wrapped invocation must be marked");
            for (index, marker) in marked {
                assert_eq!(marker.fg, accent);
                assert_eq!(marker.bg, background);
                // Interior whitespace must be tinted too, not just the name or status glyph.
                assert_eq!(buffer.content()[index + 1].bg, background);
                assert_eq!(buffer.content()[index + 6].bg, background);
            }
            let suffix = app.events[0].tool.as_ref().unwrap().rsplit_once('.').unwrap().1;
            let names = tool_lines(&app.events[0], 17, 128);
            assert!(names.len() > 1);
            assert!(names.iter().map(line_string).collect::<String>().ends_with(suffix));
            assert!(text(&buffer).contains("inv-7"));
        }
    }

    #[test]
    fn all_dispatch_outcomes_have_truthful_distinct_glyphs_and_colors() {
        let cases = [("started", Outcome::Active), ("ok", Outcome::Success),
            ("tool_error", Outcome::Error), ("transport_error", Outcome::Error),
            ("invalid_arguments", Outcome::Invalid), ("unknown_tool", Outcome::Invalid),
            ("catalog_unavailable", Outcome::Unavailable), ("native_unavailable", Outcome::Unavailable),
            ("queue_full", Outcome::Unavailable), ("cancelled", Outcome::Cancelled), ("future_status", Outcome::Other)];
        for (status, expected) in cases {
            let event = event("a", status, "Echo");
            assert_eq!(outcome(&event), expected);
            if status != "ok" {
                assert_ne!(outcome(&event).color(), theme::GREEN);
                assert_ne!(outcome(&event).icon(false), "◆");
            }
            let mut app = app(vec![event], false);
            let buffer = draw(&mut app, 120, 36);
            assert!(buffer.content().iter().any(|cell| cell.symbol() == expected.icon(false) && cell.fg == expected.color()));
        }
    }

    #[test]
    fn selection_survives_eviction_and_filter_membership_changes_and_exports_that_id() {
        let dir = tempfile::tempdir().unwrap();
        let mut app = app(vec![event("a", "started", "One"), event("b", "started", "Two"), event("c", "started", "Three")], true);
        app.export_dir = Some(dir.path().into());
        app.filter = "status:started".into();
        press(&mut app, KeyCode::Up); // b
        draw(&mut app, 120, 36);
        app.details_offset = 9;
        // a was evicted; c completed and left the active filter. b is now at visible index zero.
        app.update(vec![event("b", "started", "Two"), event("c", "ok", "Three"), event("d", "started", "Four")], MonitorStats { events: 3, evicted: 1, ..Default::default() });
        assert_eq!(app.selected_event().unwrap().invocation_id, "b");
        assert_eq!(app.details_offset, 9, "same invocation retains its detail position");
        press(&mut app, KeyCode::Char('e'));
        let exported: Event = serde_json::from_str(&fs::read_to_string(dir.path().join("b-Two.json")).unwrap()).unwrap();
        assert_eq!(exported.invocation_id, "b");
        press(&mut app, KeyCode::Down);
        assert_eq!(app.selected_event().unwrap().invocation_id, "d");
        assert_eq!(app.details_offset, 0);
        app.update(vec![event("b", "started", "Two")], MonitorStats::default());
        assert_eq!(app.selected_event().unwrap().invocation_id, "b");
        assert_eq!(app.details_offset, 0);
    }

    #[test]
    fn pause_freezes_elapsed_payload_and_stats_and_resume_catches_up() {
        let original = event("a", "started", "Echo");
        let mut app = app(vec![original.clone()], true);
        press(&mut app, KeyCode::Char('p'));
        let frozen_time = app.display_ms();
        let frozen_stats = app.stats;
        let before = text(&draw(&mut app, 120, 36));
        app.update(vec![event("a", "ok", "Echo"), event("b", "ok", "Next")], MonitorStats { events: 2, evicted: 5, ..Default::default() });
        assert!(Arc::ptr_eq(&app.events[0], &original));
        assert_eq!(app.stats, frozen_stats);
        assert_eq!(app.display_ms(), frozen_time);
        assert_eq!(text(&draw(&mut app, 120, 36)), before);
        press(&mut app, KeyCode::Char('p'));
        app.update(vec![event("a", "ok", "Echo"), event("b", "ok", "Next")], MonitorStats { events: 2, ..Default::default() });
        assert_eq!(app.events.len(), 2);
        assert_eq!(app.selected_event().unwrap().invocation_id, "b");
    }

    #[test]
    fn filter_draft_cancel_apply_empty_and_follow_have_separate_semantics() {
        let events = vec![event("a", "ok", "Echo"), event("b", "tool_error", "Fail")];
        let mut app = app(events.clone(), true);
        press(&mut app, KeyCode::Char('/'));
        for ch in "error".chars() { press(&mut app, KeyCode::Char(ch)); }
        assert!(app.filter.is_empty(), "editing must not overwrite the applied filter");
        assert_eq!(app.visible_indices(), vec![1]);
        app.update(vec![events[0].clone(), events[1].clone(), event("c", "tool_error", "FailLater")], MonitorStats::default());
        assert_eq!(app.selected_event().unwrap().invocation_id, "b", "follow must not fight draft editing");
        press(&mut app, KeyCode::Esc);
        assert!(app.filter.is_empty());
        assert_eq!(app.visible_indices().len(), 3);
        press(&mut app, KeyCode::Char('/'));
        for ch in "tool:Echo".chars() { press(&mut app, KeyCode::Char(ch)); }
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.filter, "tool:Echo");
        assert_eq!(app.selected_event().unwrap().invocation_id, "a");
        let buffer = draw(&mut app, 120, 36);
        assert!(text(&buffer).contains("Filter /tool:Echo"));
        assert!(text(&buffer).contains("1 matching / 2 hidden"));
        press(&mut app, KeyCode::Char('c'));
        press(&mut app, KeyCode::Up);
        assert!(!app.follow);
        press(&mut app, KeyCode::Char('f'));
        assert!(app.follow);
        assert_eq!(app.selected_event().unwrap().invocation_id, "c");
        app.filter = "no-such-tool".into();
        app.details_offset = usize::MAX;
        let buffer = draw(&mut app, 80, 24);
        assert!(text(&buffer).contains("No matches"));
        assert_eq!(app.details_offset, 0);
        assert!(app.selected_event().is_none());
    }

    #[test]
    fn unicode_wrap_preserves_graphemes_styles_and_cell_bounds() {
        let value = "界e\u{301}👩\u{200d}💻終".repeat(20);
        let line = Line::from(vec![Span::styled(value.clone(), fg(theme::CYAN))]);
        for width in [2, 3, 5, 17, 72] {
            let wrapped = wrap_cells(&line, width, 1024);
            assert_eq!(wrapped.iter().map(line_string).collect::<String>(), value);
            assert!(wrapped.iter().all(|line| line.width() <= width));
            assert!(wrapped.iter().flat_map(|line| &line.spans).all(|span| span.style.fg == Some(theme::CYAN)));
            let clipped = clip_cells(&value, width, false);
            assert!(Span::raw(&clipped).width() <= width);
            assert!(!clipped.contains("e…"), "combining mark must remain attached");
        }
    }

    #[test]
    fn wrapped_json_tail_is_reachable_and_scroll_is_bounded_across_resize_and_selection() {
        let mut long = (*event("long", "ok", "Payload")).clone();
        long.result = serde_json::json!({"message": "界e\u{301}👩\u{200d}💻".repeat(300), "tail": "TAIL_SENTINEL"}).to_string();
        let mut app = app(vec![Arc::new(long), event("short", "ok", "Short")], false);
        press(&mut app, KeyCode::Home);
        press(&mut app, KeyCode::Tab);
        draw(&mut app, 80, 24);
        assert!(app.details_max_offset > 20);
        for _ in 0..100 { press(&mut app, KeyCode::Char(']')); }
        let buffer = draw(&mut app, 80, 24);
        assert!(text(&buffer).contains("TAIL_SENTINEL"));
        assert_eq!(app.details_offset, app.details_max_offset);
        assert!(app.details_cache.as_ref().unwrap().lines.iter().all(|line| line.width() <= 73));
        for (width, height) in [(40, 16), (164, 46), (120, 36), (80, 24)] {
            app.details_offset = usize::MAX;
            draw(&mut app, width, height);
            assert_eq!(app.details_offset, app.details_max_offset);
            let cached = app.details_cache.as_ref().unwrap();
            assert!(cached.lines.iter().all(|line| line.width() <= cached.width));
        }
        press(&mut app, KeyCode::Down);
        assert_eq!(app.details_offset, 0);
        draw(&mut app, 80, 24);
        assert_eq!(app.selected_id.as_deref(), Some("short"));
    }

    #[test]
    fn payload_budgets_reserve_both_cards_and_disclose_display_truncation() {
        let mut huge = (*event("huge", "tool_error", "Payload")).clone();
        let payload = serde_json::json!({"rows": vec![0; 4000], "password":"[redacted]"}).to_string();
        huge.arguments = payload.clone();
        huge.result = payload;
        let lines = detail_lines(&huge, 72, true);
        assert!(lines.len() <= MAX_DETAILS_LINES);
        let text = lines.iter().map(line_string).collect::<Vec<_>>().join("\n");
        assert!(text.contains("ARGUMENTS"));
        assert!(text.contains("RESULT / ERROR"));
        assert_eq!(text.matches("display truncated").count(), 2);
        assert!(lines.iter().all(|line| line.width() == 72 || !line_string(line).starts_with('|')));
    }

    #[test]
    fn responsive_chrome_ascii_empty_and_tiny_sizes_are_safe_and_truthful() {
        for ascii in [false, true] {
            let mut app = app(vec![event("active", "started", "SummarizeMap")], ascii);
            for (width, height) in [(164, 46), (120, 36), (80, 24), (60, 16), (40, 10), (20, 6), (1, 1), (0, 0)] {
                let buffer = draw(&mut app, width, height);
                let output = text(&buffer);
                assert!(!output.contains("connecting"));
                if width >= 80 {
                    assert!(output.contains("127.0.0.1:47123/mcp"));
                    assert!(output.contains("LIVE"));
                    assert!(output.contains("CALL HISTORY"));
                }
                if ascii { assert!(output.is_ascii(), "ASCII fixtures must produce ASCII chrome at {width}x{height}"); }
            }
            press(&mut app, KeyCode::Tab);
            draw(&mut app, 80, 24);
            app.details_offset = usize::MAX;
            let buffer = draw(&mut app, 80, 24);
            let output = text(&buffer);
            assert!(output.contains("DETAILS"));
            assert!(output.contains("Waiting for result..."));
            assert!(output.contains("[Tab] calls"));
        }
        let mut empty = App::new(true, None);
        assert!(text(&draw(&mut empty, 120, 36)).contains("No invocations observed"));
    }

    #[test]
    fn viewport_is_stable_on_ticks_and_arrows_and_notices_expire_and_ctrl_c_quits() {
        let events: Vec<_> = (0..30).map(|i| event(&format!("inv-{i}"), "ok", "Echo")).collect();
        let mut app = app(events.clone(), true);
        draw(&mut app, 120, 36);
        let start = app.history_start;
        app.update(events, MonitorStats::default());
        draw(&mut app, 120, 36);
        assert_eq!(app.history_start, start);
        press(&mut app, KeyCode::Up);
        draw(&mut app, 120, 36);
        assert_eq!(app.history_start, start);
        app.notice("temporary notice");
        app.status_until = Some(Instant::now());
        draw(&mut app, 120, 36);
        assert!(app.status.is_empty());
        assert_eq!(app.handle_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)), Action::Quit);
        press(&mut app, KeyCode::Char('/'));
        assert_eq!(app.handle_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)), Action::Quit);
    }

    #[test]
    fn export_requires_explicit_directory_safe_filename_and_never_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let mut sample = (*event("../../private\n", "ok", "Take/Secret")).clone();
        sample.arguments = "{\"password\":\"[redacted]\"}".into();
        let path = export_event(dir.path(), &sample).unwrap();
        assert_eq!(path.parent(), Some(dir.path()));
        assert!(path.file_name().unwrap().to_string_lossy().chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')));
        assert!(fs::read_to_string(&path).unwrap().contains("[redacted]"));
        assert!(export_event(dir.path(), &sample).is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let mut app = app(vec![Arc::new(sample)], true);
        press(&mut app, KeyCode::Char('e'));
        assert!(app.status.contains("Export disabled"));
    }
}

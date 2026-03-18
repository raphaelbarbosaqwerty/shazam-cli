mod protocol;
mod state;
mod ui;

use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::io::FromRawFd;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use crossterm::{
    event::{self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event, KeyCode, KeyModifiers, MouseEventKind},
    execute,
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::prelude::*;

use protocol::*;
use state::*;

/// Events from either terminal input or Elixir.
enum AppEvent {
    Terminal(Event),
    Elixir(InboundMsg),
    ElixirClosed,
}

fn main() -> io::Result<()> {
    // With Erlang's nouse_stdio:
    //   fd 0 (stdin)  = terminal (free for crossterm input)
    //   fd 1 (stdout) = terminal (free for ratatui output)
    //   fd 3 = read from Elixir (Elixir Port.command writes here)
    //   fd 4 = write to Elixir (Elixir receives as port data)

    // Set up terminal on stdout (which IS the terminal now)
    terminal::enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableBracketedPaste,
        EnableMouseCapture,
    )?;

    // ⚡ Lightning strike animation before main UI
    play_lightning_animation(&mut stdout)?;

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut state = AppState::default();

    // Channel for unified event handling
    let (tx, rx) = mpsc::channel::<AppEvent>();

    // Thread 1: Read JSON from fd 3 (Elixir Port pipe)
    let tx_elixir = tx.clone();
    thread::spawn(move || {
        // fd 3 = input from Elixir (nouse_stdio mode)
        let elixir_in = unsafe { std::fs::File::from_raw_fd(3) };
        let reader = BufReader::new(elixir_in);
        for line in reader.lines() {
            match line {
                Ok(json) => {
                    if json.trim().is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<InboundMsg>(&json) {
                        Ok(msg) => {
                            if tx_elixir.send(AppEvent::Elixir(msg)).is_err() {
                                break;
                            }
                        }
                        Err(_e) => {
                            if let Ok(mut f) = OpenOptions::new()
                                .create(true)
                                .append(true)
                                .open("/tmp/shazam-tui.log")
                            {
                                let _ = writeln!(f, "JSON parse error: {} — line: {}", _e, json);
                            }
                        }
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx_elixir.send(AppEvent::ElixirClosed);
    });

    // Thread 2: Read terminal events (crossterm reads from stdin = terminal)
    let tx_term = tx;
    thread::spawn(move || loop {
        if event::poll(Duration::from_millis(50)).unwrap_or(false) {
            if let Ok(ev) = event::read() {
                if tx_term.send(AppEvent::Terminal(ev)).is_err() {
                    break;
                }
            }
        }
    });

    // Main loop: process events, render
    let mut last_refresh = std::time::Instant::now();
    while state.running {
        terminal.draw(|f| ui::draw(f, &state))?;

        // Auto-refresh overlays that show live data
        if last_refresh.elapsed() >= Duration::from_secs(3) {
            match state.view {
                View::Dashboard => {
                    send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/dashboard".into() }));
                    last_refresh = std::time::Instant::now();
                }
                View::Agents => {
                    send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/agents".into() }));
                    last_refresh = std::time::Instant::now();
                }
                View::Tasks => {
                    send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                    last_refresh = std::time::Instant::now();
                }
                _ => {}
            }
        }

        match rx.recv_timeout(Duration::from_millis(16)) {
            Ok(event) => {
                handle_event(event, &mut state);
                while let Ok(event) = rx.try_recv() {
                    handle_event(event, &mut state);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // Cleanup terminal
    terminal::disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableBracketedPaste,
        DisableMouseCapture,
    )?;
    terminal.show_cursor()?;

    Ok(())
}

fn handle_event(event: AppEvent, state: &mut AppState) {
    match event {
        AppEvent::ElixirClosed => {
            state.running = false;
        }
        AppEvent::Elixir(msg) => handle_elixir_msg(msg, state),
        AppEvent::Terminal(ev) => handle_terminal_event(ev, state),
    }
}

fn handle_elixir_msg(msg: InboundMsg, state: &mut AppState) {
    match msg {
        InboundMsg::Event(e) => {
            let (icon, color) = event_style(&e.event);
            let text = format_event_text(&e);
            let ts = e.timestamp.unwrap_or_else(chrono_now);

            // Clear matching approval from pending list
            if e.event == "task_approved" || e.event == "task_rejected" {
                if let Some(title) = &e.title {
                    state.pending_approvals.retain(|a| a.title != *title);
                }
            }

            state.push_event(EventLine {
                timestamp: ts,
                agent: e.agent.unwrap_or_default(),
                icon: icon.to_string(),
                text,
                color,
            });
        }
        InboundMsg::Status(s) => {
            state.status = s;
        }
        InboundMsg::Dashboard(d) => {
            state.dashboard_agents = d.agents;
            state.view = View::Dashboard;
        }
        InboundMsg::TaskList(t) => {
            state.task_items = t.tasks;
            state.tasks_scroll = 0;
            state.tasks_selected = 0;
            state.view = View::Tasks;
        }
        InboundMsg::AgentList(a) => {
            state.agent_list = a.agents;
            state.agents_selected = 0;
            state.view = View::Agents;
        }
        InboundMsg::ConfigInfo(c) => {
            state.config_company = c.company;
            state.config_mission = c.mission;
            state.config_entries = c.entries;
            state.view = View::Config;
        }
        InboundMsg::Approval(a) => {
            state.pending_approvals.push(a);
        }
        InboundMsg::Clear => {
            state.events.clear();
            state.scroll_offset = 0;
        }
        InboundMsg::ClearApprovals => {
            state.pending_approvals.clear();
        }
        InboundMsg::Quit => {
            state.running = false;
        }
        InboundMsg::GhostText(g) => {
            state.ghost_text = g.text;
        }
    }
}

fn handle_terminal_event(ev: Event, state: &mut AppState) {
    match ev {
        Event::Key(key) => {
            // Handle overlay keys first
            if state.view != View::Main {
                // Task action submenu
                if state.view == View::Tasks && state.task_action_menu {
                    match key.code {
                        KeyCode::Esc => {
                            state.task_action_menu = false;
                            return;
                        }
                        KeyCode::Up | KeyCode::Char('k') => {
                            state.task_action_selected = state.task_action_selected.saturating_sub(1);
                            return;
                        }
                        KeyCode::Down | KeyCode::Char('j') => {
                            let max = task_actions_for_status(
                                state.task_items.get(state.tasks_selected)
                                    .map(|t| t.status.as_str()).unwrap_or("")
                            ).len();
                            if state.task_action_selected + 1 < max {
                                state.task_action_selected += 1;
                            }
                            return;
                        }
                        KeyCode::Enter => {
                            // Execute the selected action
                            if let Some(task) = state.task_items.get(state.tasks_selected) {
                                let actions = task_actions_for_status(&task.status);
                                if let Some(action) = actions.get(state.task_action_selected) {
                                    let cmd = format_task_action_command(action, &task.id);
                                    send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                                }
                            }
                            state.task_action_menu = false;
                            // Refresh task list
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                            return;
                        }
                        _ => return,
                    }
                }

                match key.code {
                    KeyCode::Esc | KeyCode::Char('q') => {
                        state.view = View::Main;
                        state.help_scroll = 0;
                        state.task_action_menu = false;
                        return;
                    }
                    KeyCode::Enter => {
                        if state.view == View::Tasks && !state.task_items.is_empty() {
                            state.task_action_menu = true;
                            state.task_action_selected = 0;
                        }
                        return;
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        match state.view {
                            View::Help => state.help_scroll = state.help_scroll.saturating_sub(1),
                            View::Tasks => state.tasks_selected = state.tasks_selected.saturating_sub(1),
                            View::Agents => state.agents_selected = state.agents_selected.saturating_sub(1),
                            _ => {}
                        }
                        return;
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        match state.view {
                            View::Help => state.help_scroll += 1,
                            View::Tasks => {
                                if state.tasks_selected + 1 < state.task_items.len() {
                                    state.tasks_selected += 1;
                                }
                            }
                            View::Agents => {
                                if state.agents_selected + 1 < state.agent_list.len() {
                                    state.agents_selected += 1;
                                }
                            }
                            _ => {}
                        }
                        return;
                    }
                    KeyCode::PageUp => {
                        match state.view {
                            View::Help => state.help_scroll = state.help_scroll.saturating_sub(10),
                            View::Tasks => state.tasks_selected = state.tasks_selected.saturating_sub(10),
                            View::Agents => state.agents_selected = state.agents_selected.saturating_sub(10),
                            _ => {}
                        }
                        return;
                    }
                    KeyCode::PageDown => {
                        match state.view {
                            View::Help => state.help_scroll += 10,
                            View::Tasks => {
                                state.tasks_selected = (state.tasks_selected + 10).min(state.task_items.len().saturating_sub(1));
                            }
                            View::Agents => {
                                state.agents_selected = (state.agents_selected + 10).min(state.agent_list.len().saturating_sub(1));
                            }
                            _ => {}
                        }
                        return;
                    }
                    _ => return,
                }
            }

            match key.code {
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    send_to_elixir(&OutboundMsg::Command(CommandMsg {
                        raw: "/quit".into(),
                    }));
                    state.running = false;
                }
                KeyCode::Char('l') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    state.events.clear();
                    state.scroll_offset = 0;
                }
                KeyCode::Enter => {
                    let cmd = state.submit_input();
                    state.clear_attachments();
                    if !cmd.trim().is_empty() {
                        send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                    }
                }
                KeyCode::Backspace => {
                    if state.cursor_pos > 0 {
                        state.cursor_pos -= 1;
                        let byte_idx = char_to_byte_index(&state.input, state.cursor_pos);
                        state.input.remove(byte_idx);
                        state.ghost_text = suggest_command(&state.input);
                    }
                }
                KeyCode::Delete => {
                    let char_count = state.input.chars().count();
                    if state.cursor_pos < char_count {
                        let byte_idx = char_to_byte_index(&state.input, state.cursor_pos);
                        state.input.remove(byte_idx);
                        state.ghost_text = suggest_command(&state.input);
                    }
                }
                KeyCode::Left => {
                    state.cursor_pos = state.cursor_pos.saturating_sub(1);
                }
                KeyCode::Right => {
                    let char_count = state.input.chars().count();
                    if state.cursor_pos < char_count {
                        state.cursor_pos += 1;
                    } else if !state.ghost_text.is_empty() {
                        state.input.push_str(&state.ghost_text);
                        state.cursor_pos = state.input.chars().count();
                        state.ghost_text.clear();
                    }
                }
                KeyCode::Home => {
                    state.cursor_pos = 0;
                }
                KeyCode::End => {
                    state.cursor_pos = state.input.chars().count();
                }
                KeyCode::Up => {
                    state.history_up();
                }
                KeyCode::Down => {
                    state.history_down();
                }
                KeyCode::PageUp => {
                    state.scroll_offset = state
                        .scroll_offset
                        .saturating_add(10)
                        .min(state.events.len().saturating_sub(1));
                }
                KeyCode::PageDown => {
                    state.scroll_offset = state.scroll_offset.saturating_sub(10);
                }
                KeyCode::Tab => {
                    if !state.ghost_text.is_empty() {
                        state.input.push_str(&state.ghost_text);
                        state.cursor_pos = state.input.chars().count();
                        state.ghost_text.clear();
                    }
                }
                KeyCode::Esc => {
                    if state.view != View::Main {
                        state.view = View::Main;
                    }
                }
                KeyCode::Char(c) => {
                    let byte_idx = char_to_byte_index(&state.input, state.cursor_pos);
                    state.input.insert(byte_idx, c);
                    state.cursor_pos += 1;
                    // Local ghost text for slash commands
                    state.ghost_text = suggest_command(&state.input);
                }
                _ => {}
            }
        }
        Event::Paste(content) => {
            let trimmed = content.trim();
            if is_image_path(trimmed) {
                let id = state.add_image(trimmed.to_string());
                send_to_elixir(&OutboundMsg::Image(ImageMsg {
                    path: trimmed.to_string(),
                }));
                let token = format!("[Image #{}]", id);
                state.input.push_str(&token);
                state.cursor_pos = state.input.len();
            } else if content.contains('\n') {
                let line_count = content.lines().count();
                let id = state.add_paste(content.clone());
                send_to_elixir(&OutboundMsg::Paste(PasteMsg {
                    content: content.clone(),
                    line_count,
                }));
                let token = format!("[Pasted text #{} +{} lines]", id, line_count);
                state.input.push_str(&token);
                state.cursor_pos = state.input.len();
            } else {
                let byte_idx = char_to_byte_index(&state.input, state.cursor_pos);
                state.input.insert_str(byte_idx, &content);
                state.cursor_pos += content.chars().count();
            }
        }
        Event::Mouse(mouse) => {
            match mouse.kind {
                MouseEventKind::ScrollUp => {
                    if state.view == View::Main {
                        state.scroll_offset = state
                            .scroll_offset
                            .saturating_add(3)
                            .min(state.events.len().saturating_sub(1));
                    } else if state.view == View::Tasks {
                        state.tasks_selected = state.tasks_selected.saturating_sub(3);
                    } else if state.view == View::Help {
                        state.help_scroll = state.help_scroll.saturating_sub(3);
                    }
                }
                MouseEventKind::ScrollDown => {
                    if state.view == View::Main {
                        state.scroll_offset = state.scroll_offset.saturating_sub(3);
                    } else if state.view == View::Tasks {
                        state.tasks_selected = (state.tasks_selected + 3).min(state.task_items.len().saturating_sub(1));
                    } else if state.view == View::Help {
                        state.help_scroll += 3;
                    }
                }
                _ => {}
            }
        }
        Event::Resize(cols, rows) => {
            send_to_elixir(&OutboundMsg::Resize(ResizeMsg { cols, rows }));
        }
        _ => {}
    }
}

/// Command definitions: (command, description)
const COMMANDS: &[(&str, &str)] = &[
    ("/start", "start agents"),
    ("/stop", "stop agents"),
    ("/pause", "pause agents"),
    ("/resume", "resume agents"),
    ("/tasks", "list tasks"),
    ("/task ", "create task"),
    ("/approve", "approve pending task"),
    ("/approve --all", "approve all"),
    ("/aa", "approve all"),
    ("/reject ", "reject task"),
    ("/agents", "list agents"),
    ("/agent add ", "add agent (--preset senior_dev|qa|pm)"),
    ("/agent edit ", "edit agent"),
    ("/agent remove ", "remove agent"),
    ("/agent presets", "list available presets"),
    ("/team create ", "create team for domain"),
    ("/team templates", "show team template help"),
    ("/dashboard", "agent dashboard"),
    ("/config", "show configuration"),
    ("/org", "org chart"),
    ("/msg ", "send message to agent"),
    ("/auto-approve", "toggle auto-approve"),
    ("/status", "system status"),
    ("/clear", "clear screen"),
    ("/help", "show help"),
    ("/quit", "exit shazam"),
    ("/exit", "exit shazam"),
];

/// Ghost text: (completion_part, hint_part)
/// Tab accepts only completion_part, hint is display-only.
fn suggest_command(input: &str) -> String {
    if !input.starts_with('/') || input.len() < 2 {
        return String::new();
    }

    for &(cmd, _desc) in COMMANDS {
        if cmd.starts_with(input) && cmd != input {
            return cmd[input.len()..].to_string();
        }
    }

    String::new()
}

/// Returns the hint text (description) for display after ghost completion.
fn command_hint(input: &str) -> String {
    if !input.starts_with('/') {
        return String::new();
    }
    let trimmed = input.trim_end();
    for &(cmd, desc) in COMMANDS {
        let cmd_trimmed = cmd.trim_end();
        if cmd_trimmed == trimmed || (cmd.ends_with(' ') && trimmed.starts_with(cmd_trimmed)) {
            return format!(" — {}", desc);
        }
    }
    String::new()
}

/// Returns available actions for a task based on its status.
fn task_actions_for_status(status: &str) -> Vec<&'static str> {
    match status {
        "pending" => vec!["Start", "Pause", "Delete"],
        "in_progress" => vec!["Pause", "Kill"],
        "completed" => vec!["Retry", "Delete"],
        "failed" => vec!["Retry", "Delete"],
        "awaiting_approval" => vec!["Approve", "Reject"],
        "paused" => vec!["Resume", "Delete"],
        "rejected" => vec!["Retry", "Delete"],
        _ => vec!["Delete"],
    }
}

/// Maps an action name to the Elixir command string.
fn format_task_action_command(action: &str, task_id: &str) -> String {
    match action {
        "Approve" => format!("/approve {}", task_id),
        "Reject" => format!("/reject {}", task_id),
        "Pause" => format!("/pause-task {}", task_id),
        "Resume" => format!("/resume-task {}", task_id),
        "Kill" => format!("/kill-task {}", task_id),
        "Retry" => format!("/retry-task {}", task_id),
        "Delete" => format!("/delete-task {}", task_id),
        "Start" => format!("/start-task {}", task_id),
        _ => String::new(),
    }
}

fn is_image_path(s: &str) -> bool {
    let lower = s.to_lowercase();
    let extensions = [
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".heic",
    ];
    extensions.iter().any(|ext| lower.ends_with(ext))
        && !s.contains('\n')
        && (s.starts_with('/') || s.starts_with('~') || s.starts_with('.'))
}

/// Convert a char index to a byte index in a UTF-8 string.
fn char_to_byte_index(s: &str, char_idx: usize) -> usize {
    s.char_indices()
        .nth(char_idx)
        .map(|(byte_idx, _)| byte_idx)
        .unwrap_or(s.len())
}

/// Send JSON to Elixir via fd 4 (nouse_stdio output)
fn send_to_elixir(msg: &OutboundMsg) {
    if let Ok(json) = serde_json::to_string(msg) {
        // fd 4 = output to Elixir in nouse_stdio mode
        let mut elixir_out = unsafe { std::fs::File::from_raw_fd(4) };
        let _ = writeln!(elixir_out, "{}", json);
        let _ = elixir_out.flush();
        // Don't drop — from_raw_fd takes ownership and would close fd 4
        std::mem::forget(elixir_out);
    }
}

fn event_style(event_type: &str) -> (&str, EventColor) {
    match event_type {
        "task_created" => ("📋", EventColor::Blue),
        "task_started" => ("🔧", EventColor::Yellow),
        "task_completed" => ("✅", EventColor::Green),
        "task_failed" => ("❌", EventColor::Red),
        "task_awaiting_approval" => ("⚠️", EventColor::Yellow),
        "task_approved" => ("✅", EventColor::Green),
        "task_rejected" => ("🚫", EventColor::Red),
        "agent_output" => ("💬", EventColor::Cyan),
        "ralph_resumed" => ("▶️", EventColor::Green),
        "ralph_paused" => ("⏸️", EventColor::Yellow),
        "tool_use" => ("🔧", EventColor::Magenta),
        "task_killed" => ("💀", EventColor::Red),
        "task_paused" => ("⏸️", EventColor::Yellow),
        _ => (" ", EventColor::Gray),
    }
}

fn format_event_text(e: &EventMsg) -> String {
    let title = e.title.as_deref().unwrap_or("");
    match e.event.as_str() {
        "task_created" => {
            let to = e.assigned_to.as_deref().unwrap_or("");
            if to.is_empty() {
                format!("Created: {}", title)
            } else {
                format!("Created: {} → {}", title, to)
            }
        }
        "task_completed" => format!("Completed: {}", title),
        "task_failed" => format!("Failed: {}", title),
        "task_started" => format!("Started: {}", title),
        "agent_output" => {
            let text = e.text.as_deref().unwrap_or("");
            text.chars().take(120).collect()
        }
        other => format!("{}: {}", other, title),
    }
}

fn chrono_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let hours = (now % 86400) / 3600;
    let minutes = (now % 3600) / 60;
    let seconds = now % 60;
    format!("{:02}:{:02}:{:02}", hours, minutes, seconds)
}

// ── Lightning Strike Animation ─────────────────────────────────────

const BOLT: &[&str] = &[
    "                    ██▄",
    "                   ██",
    "                  ██",
    "                 ████████▄",
    "                    ██",
    "                   ██",
    "                  ██",
    "                 ████████▄",
    "                    ██",
    "                   ██",
    "                  ▀▀",
];

const LOGO: &[&str] = &[
    "       ███████╗██╗  ██╗ █████╗ ███████╗ █████╗ ███╗   ███╗",
    "       ██╔════╝██║  ██║██╔══██╗╚══███╔╝██╔══██╗████╗ ████║",
    "       ███████╗███████║███████║  ███╔╝ ███████║██╔████╔██║",
    "       ╚════██║██╔══██║██╔══██║ ███╔╝  ██╔══██║██║╚██╔╝██║",
    "       ███████║██║  ██║██║  ██║███████╗██║  ██║██║ ╚═╝ ██║",
    "       ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝",
];

fn play_lightning_animation(stdout: &mut io::Stdout) -> io::Result<()> {
    use crossterm::cursor::MoveTo;
    use crossterm::style::{SetAttribute, Attribute, SetForegroundColor, Color as CColor, ResetColor};
    use crossterm::terminal::{Clear, ClearType, size};

    let (cols, rows) = size()?;

    // Phase 1: Lightning bolt falls line by line (yellow)
    execute!(stdout, Clear(ClearType::All), MoveTo(0, 0))?;

    for (i, line) in BOLT.iter().enumerate() {
        execute!(
            stdout,
            MoveTo(0, i as u16 + 1),
            SetForegroundColor(CColor::Yellow),
            SetAttribute(Attribute::Bold),
        )?;
        write!(stdout, "{}", line)?;
        execute!(stdout, ResetColor, SetAttribute(Attribute::Reset))?;
        stdout.flush()?;
        thread::sleep(Duration::from_millis(45));
    }

    thread::sleep(Duration::from_millis(80));

    // Phase 2: Flash — fill screen with bright white briefly
    execute!(stdout, SetForegroundColor(CColor::White), SetAttribute(Attribute::Bold))?;
    for r in 0..rows {
        execute!(stdout, MoveTo(0, r))?;
        write!(stdout, "{}", " ".repeat(cols as usize))?;
    }
    stdout.flush()?;
    // Reverse video flash
    write!(stdout, "\x1b[7m")?;
    stdout.flush()?;
    thread::sleep(Duration::from_millis(70));
    write!(stdout, "\x1b[27m\x1b[0m")?;
    stdout.flush()?;

    // Phase 3: Clear and show logo in golden yellow
    execute!(stdout, Clear(ClearType::All))?;

    for (i, line) in LOGO.iter().enumerate() {
        execute!(
            stdout,
            MoveTo(0, i as u16 + 1),
            SetForegroundColor(CColor::Yellow),
            SetAttribute(Attribute::Bold),
        )?;
        write!(stdout, "{}", line)?;
        execute!(stdout, ResetColor, SetAttribute(Attribute::Reset))?;
        stdout.flush()?;
        thread::sleep(Duration::from_millis(25));
    }

    // Subtitle
    let subtitle = "       AI Agent Orchestrator v0.1.0  •  shazam.dev";
    execute!(
        stdout,
        MoveTo(0, LOGO.len() as u16 + 2),
        SetForegroundColor(CColor::DarkGrey),
    )?;
    write!(stdout, "{}", subtitle)?;
    execute!(stdout, ResetColor)?;
    stdout.flush()?;

    thread::sleep(Duration::from_millis(600));

    // Clear for main TUI
    execute!(stdout, Clear(ClearType::All), MoveTo(0, 0))?;
    stdout.flush()?;

    Ok(())
}

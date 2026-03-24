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

fn main() {
    // --check flag: verify binary works without starting TUI
    if std::env::args().any(|a| a == "--check") {
        println!("shazam-tui ok");
        return;
    }

    // Log any fatal errors so they can be diagnosed
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("PANIC: {}", info);
        eprintln!("{}", msg);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open("/tmp/shazam-tui.log") {
            let _ = writeln!(f, "{}", msg);
        }
    }));

    if let Err(e) = real_main() {
        let msg = format!("FATAL: {}", e);
        eprintln!("{}", msg);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open("/tmp/shazam-tui.log") {
            let _ = writeln!(f, "{}", msg);
        }
        // Try to restore terminal before exiting
        let _ = terminal::disable_raw_mode();
        let mut stdout = io::stdout();
        let _ = execute!(stdout, LeaveAlternateScreen, DisableBracketedPaste, DisableMouseCapture);
        std::process::exit(1);
    }
}

fn tui_log(msg: &str) {
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open("/tmp/shazam-tui.log") {
        let _ = writeln!(f, "{}", msg);
    }
}

fn real_main() -> io::Result<()> {
    tui_log("startup: begin");

    // With Erlang's nouse_stdio:
    //   fd 0 (stdin)  = terminal (free for crossterm input)
    //   fd 1 (stdout) = terminal (free for ratatui output)
    //   fd 3 = read from Elixir (Elixir Port.command writes here)
    //   fd 4 = write to Elixir (Elixir receives as port data)

    // Verify fd 3 exists before proceeding
    let fd3_ok = unsafe { libc::fcntl(3, libc::F_GETFD) } != -1;
    let fd4_ok = unsafe { libc::fcntl(4, libc::F_GETFD) } != -1;
    tui_log(&format!("startup: fd3={} fd4={}", fd3_ok, fd4_ok));

    if !fd3_ok || !fd4_ok {
        tui_log("startup: fd3/fd4 not available — not launched from Elixir port?");
        eprintln!("Error: shazam-tui must be launched from shazam (Elixir port with nouse_stdio)");
        return Ok(());
    }

    // Set up terminal on stdout (which IS the terminal now)
    tui_log("startup: enabling raw mode");
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

    // Load persistent command history
    let history_path = dirs_or_home(".shazam/tui_history");
    state.input_history = load_history(&history_path);
    state.history_file = Some(history_path);

    // Channel for unified event handling
    let (tx, rx) = mpsc::channel::<AppEvent>();

    // Thread 1: Read JSON from fd 3 (Elixir Port pipe)
    let tx_elixir = tx.clone();
    thread::spawn(move || {
        tui_log("fd3-reader: thread started");
        // fd 3 = input from Elixir (nouse_stdio mode)
        let elixir_in = unsafe { std::fs::File::from_raw_fd(3) };
        let reader = BufReader::new(elixir_in);
        let mut line_count = 0u32;
        for line in reader.lines() {
            match line {
                Ok(json) => {
                    line_count += 1;
                    if line_count <= 3 {
                        tui_log(&format!("fd3-reader: line {} len={}", line_count, json.len()));
                    }
                    if json.trim().is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<InboundMsg>(&json) {
                        Ok(msg) => {
                            if tx_elixir.send(AppEvent::Elixir(msg)).is_err() {
                                tui_log("fd3-reader: channel closed, breaking");
                                break;
                            }
                        }
                        Err(_e) => {
                            tui_log(&format!("fd3-reader: JSON parse error: {} — line: {}", _e, json));
                        }
                    }
                }
                Err(e) => {
                    tui_log(&format!("fd3-reader: read error: {}", e));
                    break;
                }
            }
        }
        tui_log(&format!("fd3-reader: exiting after {} lines", line_count));
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
    tui_log("main-loop: entering");
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

    tui_log("main-loop: exited (running=false)");

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
            tui_log("event: ElixirClosed — shutting down");
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
            let was_in_tasks = matches!(state.view, View::Tasks | View::TaskDetail);
            state.task_items = t.tasks;
            if !was_in_tasks {
                state.tasks_scroll = 0;
                state.tasks_selected = 0;
                state.view = View::Tasks;
            } else if state.tasks_selected >= state.task_items.len() && !state.task_items.is_empty() {
                state.tasks_selected = state.task_items.len() - 1;
            }
        }
        InboundMsg::AgentList(a) => {
            let was_in_agents = matches!(state.view, View::Agents);
            state.agent_list = a.agents;
            if !was_in_agents {
                state.agents_selected = 0;
                state.view = View::Agents;
            } else if state.agents_selected >= state.agent_list.len() && !state.agent_list.is_empty() {
                state.agents_selected = state.agent_list.len() - 1;
            }
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
                // Task detail view
                if state.view == View::TaskDetail {
                    match key.code {
                        KeyCode::Esc | KeyCode::Char('q') => {
                            state.view = View::Tasks;
                            state.task_detail_scroll = 0;
                            return;
                        }
                        KeyCode::Up | KeyCode::Char('k') => {
                            state.task_detail_scroll = state.task_detail_scroll.saturating_sub(1);
                            return;
                        }
                        KeyCode::Down | KeyCode::Char('j') => {
                            state.task_detail_scroll += 1;
                            return;
                        }
                        KeyCode::PageUp => {
                            state.task_detail_scroll = state.task_detail_scroll.saturating_sub(10);
                            return;
                        }
                        KeyCode::PageDown => {
                            state.task_detail_scroll += 10;
                            return;
                        }
                        // Inline actions from detail view
                        KeyCode::Char('a') => {
                            if let Some(task) = state.task_items.get(state.tasks_selected) {
                                let cmd = format!("/approve {}", task.id);
                                send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                                send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                            }
                            state.view = View::Tasks;
                            state.task_detail_scroll = 0;
                            return;
                        }
                        KeyCode::Char('r') => {
                            if let Some(task) = state.task_items.get(state.tasks_selected) {
                                let cmd = format!("/reject {}", task.id);
                                send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                                send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                            }
                            state.view = View::Tasks;
                            state.task_detail_scroll = 0;
                            return;
                        }
                        _ => return,
                    }
                }

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
                        state.task_detail_scroll = 0;
                        return;
                    }
                    KeyCode::Enter => {
                        if state.view == View::Tasks && !state.task_items.is_empty() {
                            // Open task detail view
                            state.view = View::TaskDetail;
                            state.task_detail_scroll = 0;
                        }
                        return;
                    }
                    // Inline task action keybindings (Task 4)
                    KeyCode::Char('a') if state.view == View::Tasks => {
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/approve {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('r') if state.view == View::Tasks => {
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/reject {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('t') if state.view == View::Tasks => {
                        // 't' = retry task
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/retry-task {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('x') if state.view == View::Tasks => {
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/kill-task {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('p') if state.view == View::Tasks => {
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/pause-task {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('d') if state.view == View::Tasks => {
                        // 'd' opens detail view
                        if !state.task_items.is_empty() {
                            state.view = View::TaskDetail;
                            state.task_detail_scroll = 0;
                        }
                        return;
                    }
                    KeyCode::Delete | KeyCode::Backspace if state.view == View::Tasks => {
                        // Delete/Backspace removes selected task
                        if let Some(task) = state.task_items.get(state.tasks_selected) {
                            let cmd = format!("/delete-task {}", task.id);
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                            send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: "/tasks".into() }));
                        }
                        return;
                    }
                    KeyCode::Char('m') if state.view == View::Tasks => {
                        // Open action menu (alternative to Enter for action menu)
                        if !state.task_items.is_empty() {
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
                        if let Some(ref path) = state.history_file {
                            save_history_line(path, &cmd);
                        }
                        send_to_elixir(&OutboundMsg::Command(CommandMsg { raw: cmd }));
                    }
                }
                KeyCode::Backspace => {
                    if state.cursor_pos > 0 {
                        state.cursor_pos -= 1;
                        let byte_start = char_to_byte_index(&state.input, state.cursor_pos);
                        let byte_end = char_to_byte_index(&state.input, state.cursor_pos + 1);
                        state.input.drain(byte_start..byte_end);
                        state.ghost_text = suggest_command(&state.input);
                    }
                }
                KeyCode::Delete => {
                    let char_count = state.input.chars().count();
                    if state.cursor_pos < char_count {
                        let byte_start = char_to_byte_index(&state.input, state.cursor_pos);
                        let byte_end = char_to_byte_index(&state.input, state.cursor_pos + 1);
                        state.input.drain(byte_start..byte_end);
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
            } else if content.contains('\n') || content.len() > 100 {
                let line_count = content.lines().count();
                let char_count = content.chars().count();
                let id = state.add_paste(content.clone());
                send_to_elixir(&OutboundMsg::Paste(PasteMsg {
                    content: content.clone(),
                    line_count,
                }));
                let token = if line_count > 1 {
                    format!("[Paste #{} — {} lines]", id, line_count)
                } else {
                    format!("[Paste #{} — {} chars]", id, char_count)
                };
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
                    } else if state.view == View::TaskDetail {
                        state.task_detail_scroll = state.task_detail_scroll.saturating_sub(3);
                    } else if state.view == View::Help {
                        state.help_scroll = state.help_scroll.saturating_sub(3);
                    }
                }
                MouseEventKind::ScrollDown => {
                    if state.view == View::Main {
                        state.scroll_offset = state.scroll_offset.saturating_sub(3);
                    } else if state.view == View::Tasks {
                        state.tasks_selected = (state.tasks_selected + 3).min(state.task_items.len().saturating_sub(1));
                    } else if state.view == View::TaskDetail {
                        state.task_detail_scroll += 3;
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
    // System
    ("/start", "start agents"),
    ("/stop", "pause agents"),
    ("/resume", "resume agents"),
    ("/restart", "restart shazam"),
    ("/status", "refresh status bar"),
    ("/dashboard", "open agent dashboard"),
    ("/config", "show configuration"),
    ("/health", "health check"),
    ("/memory", "show memory/token usage"),
    ("/workspaces", "list configured workspaces"),
    ("/clear", "clear screen"),
    ("/help", "show help"),
    ("/quit", "exit shazam"),
    ("/exit", "exit shazam"),
    // Tasks
    ("/tasks", "list tasks"),
    ("/tasks --sync", "import from .shazam/tasks/"),
    ("/tasks --export", "export to .shazam/tasks/"),
    ("/tasks --clear", "clear all tasks"),
    ("/task ", "create task"),
    ("/approve ", "approve task by ID"),
    ("/approve-all", "approve all pending"),
    ("/aa", "approve all pending"),
    ("/reject ", "reject task"),
    ("/retry-all", "retry all failed tasks"),
    ("/retry-task ", "retry failed task"),
    ("/pause-task ", "pause a task"),
    ("/resume-task ", "resume a task"),
    ("/kill-task ", "kill running task"),
    ("/delete-task ", "delete a task"),
    ("/search ", "search tasks by title"),
    ("/export", "export tasks to markdown"),
    // Agents
    ("/agents", "list agents"),
    ("/agent add ", "add agent (--preset senior_dev|qa|pm)"),
    ("/agent edit ", "edit agent"),
    ("/agent remove ", "remove agent"),
    ("/agent presets", "list available presets"),
    ("/agents --init", "generate .md config files"),
    ("/org", "org chart"),
    ("/team create ", "create team for domain"),
    ("/team templates", "show team template help"),
    ("/msg ", "send message to agent"),
    ("/auto-approve", "toggle auto-approve (session only)"),
    // Plugins
    ("/plugins", "list loaded plugins"),
    ("/plugins reload", "reload plugins from disk"),
    ("/plugins install ", "install plugin from GitHub"),
    ("/plugins remove ", "remove a plugin"),
    // Tools
    ("/knowledge", "show knowledge bank files"),
    ("/knowledge --update", "update knowledge bank"),
    ("/review ", "review a PR"),
    ("/review --post ", "post review to GitHub"),
    ("/review --check ", "verify changes addressed"),
    ("/review --resolve ", "resolve conversation threads"),
    ("/review --learn", "learn from merged PRs"),
    ("/review --patterns", "show learned patterns"),
    ("/plan ", "create execution plan"),
    ("/plan --list", "list all plans"),
    ("/plan --show ", "show plan details"),
    ("/plan --approve ", "approve and create tasks"),
    ("/qa", "list QA docs"),
    ("/qa --generate ", "generate QA doc"),
    ("/qa --validate ", "run QA validation"),
    ("/qa --report", "generate QA report"),
    ("/qa --auto ", "toggle auto QA (session only)"),
    ("/github sync", "sync from GitHub Projects"),
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

// ── Persistent History ─────────────────────────────────────────────

fn dirs_or_home(relative: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    format!("{}/{}", home, relative)
}

fn load_history(path: &str) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(String::from)
        .collect()
}

fn save_history_line(path: &str, line: &str) {
    use std::io::Write;
    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{}", line);
    }
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

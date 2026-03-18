/// TUI rendering using ratatui — declarative layout, no manual ANSI.
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Cell, Clear, Paragraph, Row, Scrollbar, ScrollbarOrientation, ScrollbarState, Table, Wrap},
    Frame,
};
use unicode_width::UnicodeWidthChar;

use crate::state::{AppState, Attachment, EventColor, EventLine, View};

/// Main render function — called every frame.
pub fn draw(f: &mut Frame, state: &AppState) {
    let size = f.area();

    // Calculate input height based on content width
    let prompt_width: u16 = 8; // "shazam❯ "
    let input_display_width: u16 = state.input.chars()
        .map(|c| UnicodeWidthChar::width(c).unwrap_or(1) as u16)
        .sum();
    let ghost_width: u16 = if !state.ghost_text.is_empty() && state.cursor_pos == state.input.chars().count() {
        state.ghost_text.chars().map(|c| UnicodeWidthChar::width(c).unwrap_or(1) as u16).sum()
    } else {
        0
    };
    let total_input_width = prompt_width + input_display_width + ghost_width;
    let usable_width = size.width.max(1);
    let input_lines = ((total_input_width as f32) / (usable_width as f32)).ceil().max(1.0) as u16;
    let input_height = input_lines.min(6); // Cap at 6 lines

    // Main layout: [events | status_bar | separator | input]
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(3),              // Events scroll area
            Constraint::Length(1),           // Status bar
            Constraint::Length(1),           // Separator
            Constraint::Length(input_height), // Input (dynamic)
        ])
        .split(size);

    draw_events(f, chunks[0], state);
    draw_status_bar(f, chunks[1], state);
    draw_separator(f, chunks[2]);
    draw_input(f, chunks[3], state);

    // Overlay views
    match state.view {
        View::Dashboard => draw_dashboard_overlay(f, size, state),
        View::Help => draw_help_overlay(f, size, state),
        View::Tasks => draw_tasks_overlay(f, size, state),
        View::Agents => draw_agents_overlay(f, size, state),
        View::Config => draw_config_overlay(f, size, state),
        View::Main => {
            // Draw approval notification if any
            if !state.pending_approvals.is_empty() {
                draw_approval_bar(f, size, state);
            }
        }
    }
}

fn draw_events(f: &mut Frame, area: Rect, state: &AppState) {
    let events: Vec<&EventLine> = state.events.iter().collect();
    let total = events.len();
    let visible = area.height as usize;

    // Clamp scroll_offset so we never scroll past the first event
    let max_scroll = total.saturating_sub(visible);
    let scroll = state.scroll_offset.min(max_scroll);

    // Calculate visible window based on scroll offset
    let end = total.saturating_sub(scroll);
    let start = end.saturating_sub(visible);

    let lines: Vec<Line> = events[start..end]
        .iter()
        .map(|e| format_event_line(e))
        .collect();

    // Reserve 1 column on the right for the scrollbar
    let content_area = Rect {
        width: area.width.saturating_sub(1),
        ..area
    };

    let paragraph = Paragraph::new(lines).wrap(Wrap { trim: false });
    f.render_widget(paragraph, content_area);

    // Scrollbar
    if total > visible {
        let position = max_scroll.saturating_sub(scroll);
        let mut scrollbar_state = ScrollbarState::new(max_scroll)
            .position(position);

        f.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_style(Style::default().fg(Color::Yellow))
                .track_style(Style::default().fg(Color::Rgb(40, 40, 50)))
                .begin_symbol(Some("▲"))
                .end_symbol(Some("▼")),
            area,
            &mut scrollbar_state,
        );
    }
}

fn format_event_line(e: &EventLine) -> Line<'static> {
    let color = match e.color {
        EventColor::Blue => Color::Blue,
        EventColor::Yellow => Color::Yellow,
        EventColor::Green => Color::Green,
        EventColor::Red => Color::Red,
        EventColor::Cyan => Color::Cyan,
        EventColor::Magenta => Color::Magenta,
        EventColor::Gray => Color::DarkGray,
    };

    Line::from(vec![
        Span::styled(
            format!("{} ", e.timestamp),
            Style::default().fg(Color::DarkGray),
        ),
        Span::styled(
            format!("[{}]", e.agent),
            Style::default().fg(color),
        ),
        Span::raw(format!("  {} {}", e.icon, e.text)),
    ])
}

fn draw_status_bar(f: &mut Frame, area: Rect, state: &AppState) {
    let s = &state.status;
    let company = s.company.as_deref().unwrap_or("Shazam");
    let status_str = s.status.as_deref().unwrap_or("idle");
    let (status_color, status_icon) = match status_str {
        "running" => (Color::Green, "●"),
        "paused" => (Color::Yellow, "⏸"),
        _ => (Color::DarkGray, "○"),
    };

    let agents = format!(
        "{}↑/{}",
        s.agents_active.unwrap_or(0),
        s.agents_total.unwrap_or(0)
    );

    let awaiting = s.tasks_awaiting.unwrap_or(0);
    let tasks = format!(
        "P:{} R:{} D:{}",
        s.tasks_pending.unwrap_or(0),
        s.tasks_running.unwrap_or(0),
        s.tasks_done.unwrap_or(0)
    );

    let budget_used = s.budget_used.unwrap_or(0);
    let budget_total = s.budget_total.unwrap_or(1);
    let budget_pct = if budget_total > 0 {
        (budget_used as f64 / budget_total as f64 * 100.0).min(100.0) as u32
    } else {
        0
    };
    let budget_color = if budget_pct > 90 {
        Color::Red
    } else if budget_pct > 70 {
        Color::Yellow
    } else {
        Color::Green
    };

    let mut spans = vec![
        Span::styled(
            format!(" {} ", company),
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{} {} ", status_icon, status_str),
            Style::default().fg(status_color),
        ),
        Span::styled("│ ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            format!("Agents: {} ", agents),
            Style::default().fg(Color::Cyan),
        ),
        Span::styled("│ ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            format!("Tasks: {} ", tasks),
            Style::default().fg(Color::White),
        ),
    ];

    // Show awaiting approval count prominently
    if awaiting > 0 {
        spans.push(Span::styled("│ ", Style::default().fg(Color::DarkGray)));
        spans.push(Span::styled(
            format!("⚠ {} awaiting ", awaiting),
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ));
    }

    spans.push(Span::styled("│ ", Style::default().fg(Color::DarkGray)));
    spans.push(Span::styled(
        format!("Budget: {}% ", budget_pct),
        Style::default().fg(budget_color),
    ));

    let line = Line::from(spans);

    let bar = Paragraph::new(line).style(
        Style::default()
            .bg(Color::Rgb(30, 30, 40))
            .fg(Color::White),
    );
    f.render_widget(bar, area);
}

fn draw_separator(f: &mut Frame, area: Rect) {
    let sep = "─".repeat(area.width as usize);
    let line = Paragraph::new(Line::from(Span::styled(
        sep,
        Style::default().fg(Color::DarkGray),
    )));
    f.render_widget(line, area);
}

fn draw_input(f: &mut Frame, area: Rect, state: &AppState) {
    let prompt = Span::styled(
        "shazam❯ ",
        Style::default()
            .fg(Color::Yellow)
            .add_modifier(Modifier::BOLD),
    );

    let mut spans = vec![prompt, Span::raw(&state.input)];

    // Ghost text (completable part) + hint (display-only description)
    if state.cursor_pos == state.input.chars().count() {
        if !state.ghost_text.is_empty() {
            spans.push(Span::styled(
                &state.ghost_text,
                Style::default().fg(Color::DarkGray),
            ));
        }
        // Show command hint after completion or exact match
        let full = format!("{}{}", &state.input, &state.ghost_text);
        let hint = crate::command_hint(&full);
        if !hint.is_empty() {
            spans.push(Span::styled(
                hint,
                Style::default().fg(Color::Rgb(80, 80, 100)),
            ));
        }
    }

    // Attachment indicators
    for att in &state.attachments {
        match att {
            Attachment::Paste { id, lines, .. } => {
                spans.push(Span::raw(" "));
                spans.push(Span::styled(
                    format!("[Pasted text #{} +{} lines]", id, lines),
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::DIM),
                ));
            }
            Attachment::Image { id, .. } => {
                spans.push(Span::raw(" "));
                spans.push(Span::styled(
                    format!("[Image #{}]", id),
                    Style::default()
                        .fg(Color::Magenta)
                        .add_modifier(Modifier::DIM),
                ));
            }
        }
    }

    // Build the full display string for manual line splitting
    let prompt_str = "shazam❯ ";
    let mut full_text = String::from(prompt_str);
    full_text.push_str(&state.input);
    if !state.ghost_text.is_empty() && state.cursor_pos == state.input.chars().count() {
        full_text.push_str(&state.ghost_text);
    }

    // Split into visual lines manually (character-level, no word wrap)
    let line_width = area.width.max(1) as usize;
    let mut visual_lines: Vec<Vec<Span>> = Vec::new();
    let mut current_line: Vec<Span> = Vec::new();
    let mut current_width: usize = 0;

    for span in &spans {
        let span_content = span.content.as_ref();
        let mut chunk = String::new();

        for ch in span_content.chars() {
            let ch_w = UnicodeWidthChar::width(ch).unwrap_or(1);
            if current_width + ch_w > line_width {
                if !chunk.is_empty() {
                    current_line.push(Span::styled(chunk.clone(), span.style));
                    chunk.clear();
                }
                visual_lines.push(std::mem::take(&mut current_line));
                current_width = 0;
            }
            chunk.push(ch);
            current_width += ch_w;
        }
        if !chunk.is_empty() {
            current_line.push(Span::styled(chunk, span.style));
        }
    }
    if !current_line.is_empty() {
        visual_lines.push(current_line);
    }

    let lines: Vec<Line> = visual_lines.into_iter().map(Line::from).collect();
    let input_paragraph = Paragraph::new(lines);
    f.render_widget(input_paragraph, area);

    // Position cursor
    let prompt_w: u16 = 8;
    let display_width: u16 = state.input.chars()
        .take(state.cursor_pos)
        .map(|c| UnicodeWidthChar::width(c).unwrap_or(1) as u16)
        .sum();
    let total_offset = prompt_w + display_width;
    let lw = area.width.max(1);
    let cursor_y = area.y + (total_offset / lw);
    let cursor_x = area.x + (total_offset % lw);
    let cursor_y = cursor_y.min(area.y + area.height.saturating_sub(1));
    f.set_cursor_position((cursor_x, cursor_y));
}

fn draw_dashboard_overlay(f: &mut Frame, area: Rect, state: &AppState) {
    let popup_area = centered_rect(80, 70, area);
    f.render_widget(Clear, popup_area);

    let block = Block::default()
        .title(" Dashboard — Press ESC to close ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Yellow))
        .style(Style::default().bg(Color::Rgb(20, 20, 30)));

    let inner = block.inner(popup_area);
    f.render_widget(block, popup_area);

    if state.dashboard_agents.is_empty() {
        let msg = Paragraph::new("No agents running.")
            .style(Style::default().fg(Color::DarkGray));
        f.render_widget(msg, inner);
        return;
    }

    let header = Row::new(vec![
        Cell::from("Agent").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Role").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Status").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Domain").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Done").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Fail").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Tokens").style(Style::default().add_modifier(Modifier::BOLD)),
        Cell::from("Task").style(Style::default().add_modifier(Modifier::BOLD)),
    ])
    .height(1)
    .bottom_margin(1);

    let rows: Vec<Row> = state
        .dashboard_agents
        .iter()
        .map(|a| {
            let status_style = match a.status.as_deref() {
                Some("working") => Style::default().fg(Color::Green),
                Some("thinking") => Style::default().fg(Color::Blue),
                Some("idle") => Style::default().fg(Color::DarkGray),
                Some("error") => Style::default().fg(Color::Red),
                _ => Style::default(),
            };
            Row::new(vec![
                Cell::from(a.name.clone()).style(Style::default().fg(Color::Cyan)),
                Cell::from(a.role.clone().unwrap_or_default()),
                Cell::from(a.status.clone().unwrap_or_else(|| "idle".into()))
                    .style(status_style),
                Cell::from(a.domain.clone().unwrap_or_else(|| "-".into())),
                Cell::from(format!("{}", a.tasks_completed.unwrap_or(0))),
                Cell::from(format!("{}", a.tasks_failed.unwrap_or(0)))
                    .style(Style::default().fg(Color::Red)),
                Cell::from(format_tokens(a.tokens_used.unwrap_or(0))),
                Cell::from(
                    a.current_task
                        .clone()
                        .unwrap_or_else(|| "-".into()),
                ),
            ])
        })
        .collect();

    let table = Table::new(
        rows,
        [
            Constraint::Length(14),
            Constraint::Length(12),
            Constraint::Length(10),
            Constraint::Length(10),
            Constraint::Length(5),
            Constraint::Length(5),
            Constraint::Length(8),
            Constraint::Min(10),
        ],
    )
    .header(header)
    .style(Style::default().fg(Color::White));

    f.render_widget(table, inner);
}

fn draw_tasks_overlay(f: &mut Frame, area: Rect, state: &AppState) {
    let popup_area = centered_rect(85, 80, area);
    f.render_widget(Clear, popup_area);

    let total = state.task_items.len();
    let title = format!(" Tasks ({}) — ↑↓ navigate, ESC close ", total);

    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Yellow))
        .style(Style::default().bg(Color::Rgb(20, 20, 30)));

    let inner = block.inner(popup_area);
    f.render_widget(block, popup_area);

    if state.task_items.is_empty() {
        let msg = Paragraph::new("No tasks found.")
            .style(Style::default().fg(Color::DarkGray));
        f.render_widget(msg, inner);
        return;
    }

    // Group tasks by status for summary bar
    let mut pending = 0u32;
    let mut running = 0u32;
    let mut completed = 0u32;
    let mut failed = 0u32;
    let mut awaiting = 0u32;
    let mut other = 0u32;
    for t in &state.task_items {
        match t.status.as_str() {
            "pending" => pending += 1,
            "in_progress" => running += 1,
            "completed" => completed += 1,
            "failed" => failed += 1,
            "awaiting_approval" => awaiting += 1,
            _ => other += 1,
        }
    }

    // Layout: summary line + separator + table
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // Summary
            Constraint::Length(1), // Separator
            Constraint::Min(3),   // Table
        ])
        .split(inner);

    // Summary bar
    let mut summary_spans = vec![
        Span::styled("  ", Style::default()),
    ];
    if pending > 0 {
        summary_spans.push(Span::styled(
            format!("● {} pending  ", pending),
            Style::default().fg(Color::Blue),
        ));
    }
    if running > 0 {
        summary_spans.push(Span::styled(
            format!("● {} running  ", running),
            Style::default().fg(Color::Yellow),
        ));
    }
    if awaiting > 0 {
        summary_spans.push(Span::styled(
            format!("● {} awaiting  ", awaiting),
            Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
        ));
    }
    if completed > 0 {
        summary_spans.push(Span::styled(
            format!("● {} done  ", completed),
            Style::default().fg(Color::Green),
        ));
    }
    if failed > 0 {
        summary_spans.push(Span::styled(
            format!("● {} failed  ", failed),
            Style::default().fg(Color::Red),
        ));
    }
    if other > 0 {
        summary_spans.push(Span::styled(
            format!("● {} other  ", other),
            Style::default().fg(Color::DarkGray),
        ));
    }
    f.render_widget(Paragraph::new(Line::from(summary_spans)), chunks[0]);

    // Separator
    let sep = "─".repeat(chunks[1].width as usize);
    f.render_widget(
        Paragraph::new(Span::styled(sep, Style::default().fg(Color::Rgb(50, 50, 60)))),
        chunks[1],
    );

    // Table header
    let header = Row::new(vec![
        Cell::from(" Status").style(Style::default().fg(Color::DarkGray).add_modifier(Modifier::BOLD)),
        Cell::from("Agent").style(Style::default().fg(Color::DarkGray).add_modifier(Modifier::BOLD)),
        Cell::from("Title").style(Style::default().fg(Color::DarkGray).add_modifier(Modifier::BOLD)),
        Cell::from("Created").style(Style::default().fg(Color::DarkGray).add_modifier(Modifier::BOLD)),
    ])
    .height(1)
    .bottom_margin(0);

    let table_height = chunks[2].height.saturating_sub(2) as usize; // minus header

    // Auto-scroll to keep selected visible
    let scroll = if state.tasks_selected >= state.tasks_scroll + table_height {
        state.tasks_selected.saturating_sub(table_height - 1)
    } else if state.tasks_selected < state.tasks_scroll {
        state.tasks_selected
    } else {
        state.tasks_scroll
    };

    let rows: Vec<Row> = state
        .task_items
        .iter()
        .enumerate()
        .skip(scroll)
        .take(table_height)
        .map(|(i, t)| {
            let (icon, status_color) = task_status_style(&t.status);
            let is_selected = i == state.tasks_selected;

            let status_cell = Cell::from(format!(" {} {}", icon, short_status(&t.status)))
                .style(Style::default().fg(status_color));
            let agent_cell = Cell::from(t.assigned_to.as_deref().unwrap_or("—").to_string())
                .style(Style::default().fg(Color::Cyan));
            let title_cell = Cell::from(truncate_str(&t.title, 50))
                .style(Style::default().fg(Color::White));
            let time_cell = Cell::from(t.created_at.as_deref().unwrap_or("").to_string())
                .style(Style::default().fg(Color::DarkGray));

            let row = Row::new(vec![status_cell, agent_cell, title_cell, time_cell]);
            if is_selected {
                row.style(Style::default().bg(Color::Rgb(40, 40, 60)))
            } else {
                row
            }
        })
        .collect();

    let table = Table::new(
        rows,
        [
            Constraint::Length(14),  // Status
            Constraint::Length(14),  // Agent
            Constraint::Min(20),    // Title
            Constraint::Length(10), // Created
        ],
    )
    .header(header)
    .style(Style::default().fg(Color::White));

    f.render_widget(table, chunks[2]);

    // Scrollbar
    if total > table_height {
        let mut scrollbar_state = ScrollbarState::new(total.saturating_sub(table_height))
            .position(scroll);

        let scrollbar_area = Rect {
            x: popup_area.x + popup_area.width - 1,
            y: chunks[2].y + 1,
            width: 1,
            height: chunks[2].height.saturating_sub(1),
        };

        f.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_style(Style::default().fg(Color::Yellow))
                .track_style(Style::default().fg(Color::Rgb(40, 40, 50))),
            scrollbar_area,
            &mut scrollbar_state,
        );
    }

    // Action menu popup
    if state.task_action_menu {
        if let Some(task) = state.task_items.get(state.tasks_selected) {
            let actions = crate::task_actions_for_status(&task.status);
            if !actions.is_empty() {
                let menu_height = actions.len() as u16 + 2; // +2 for border
                let menu_width: u16 = 22;

                // Position near the selected row
                let visible_row = state.tasks_selected.saturating_sub(scroll) as u16;
                let menu_y = (chunks[2].y + visible_row + 1).min(popup_area.y + popup_area.height - menu_height);
                let menu_x = popup_area.x + 10;

                let menu_area = Rect {
                    x: menu_x,
                    y: menu_y,
                    width: menu_width,
                    height: menu_height,
                };

                f.render_widget(Clear, menu_area);

                let menu_block = Block::default()
                    .title(" Actions ")
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::Yellow))
                    .style(Style::default().bg(Color::Rgb(30, 30, 45)));

                let menu_inner = menu_block.inner(menu_area);
                f.render_widget(menu_block, menu_area);

                let action_lines: Vec<Line> = actions.iter().enumerate().map(|(i, action)| {
                    let (icon, color) = action_style(action);
                    if i == state.task_action_selected {
                        Line::from(vec![
                            Span::styled("▸ ", Style::default().fg(Color::Yellow)),
                            Span::styled(format!("{} {}", icon, action), Style::default().fg(color).add_modifier(Modifier::BOLD).bg(Color::Rgb(50, 50, 70))),
                        ])
                    } else {
                        Line::from(vec![
                            Span::raw("  "),
                            Span::styled(format!("{} {}", icon, action), Style::default().fg(color)),
                        ])
                    }
                }).collect();

                f.render_widget(Paragraph::new(action_lines), menu_inner);
            }
        }
    }
}

fn action_style(action: &str) -> (&str, Color) {
    match action {
        "Approve" => ("✓", Color::Green),
        "Reject" => ("✗", Color::Red),
        "Start" => ("▶", Color::Green),
        "Pause" => ("⏸", Color::Yellow),
        "Resume" => ("▶", Color::Green),
        "Kill" => ("✗", Color::Red),
        "Retry" => ("↻", Color::Cyan),
        "Delete" => ("🗑", Color::Red),
        _ => (" ", Color::White),
    }
}

fn draw_agents_overlay(f: &mut Frame, area: Rect, state: &AppState) {
    let popup_area = centered_rect(85, 80, area);
    f.render_widget(Clear, popup_area);

    let total = state.agent_list.len();
    let title = format!(" Agents ({}) — ↑↓ navigate, ESC close ", total);

    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Yellow))
        .style(Style::default().bg(Color::Rgb(20, 20, 30)));

    let inner = block.inner(popup_area);
    f.render_widget(block, popup_area);

    if state.agent_list.is_empty() {
        let msg = Paragraph::new("No agents configured.")
            .style(Style::default().fg(Color::DarkGray));
        f.render_widget(msg, inner);
        return;
    }

    // Two-panel layout: list on top, detail on bottom
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(5),    // Agent list (grouped)
            Constraint::Length(1), // Separator
            Constraint::Length(6), // Detail panel
        ])
        .split(inner);

    // Group agents by domain, preserving original indices for selection
    let mut domains: std::collections::BTreeMap<String, Vec<(usize, &crate::protocol::AgentInfo)>> = std::collections::BTreeMap::new();
    for (i, a) in state.agent_list.iter().enumerate() {
        let domain = a.domain.as_deref().unwrap_or("general").to_string();
        domains.entry(domain).or_default().push((i, a));
    }

    // Build visual rows with domain headers
    let mut visual_lines: Vec<Line> = Vec::new();
    let col_widths = [14usize, 18, 12, 5, 5, 8];

    for (domain, agents) in &domains {
        // Domain header
        let header_text = format!("─── {} ", domain);
        let pad = chunks[0].width as usize - header_text.len().min(chunks[0].width as usize);
        visual_lines.push(Line::from(Span::styled(
            format!("{}{}", header_text, "─".repeat(pad)),
            Style::default().fg(Color::Rgb(100, 100, 140)).add_modifier(Modifier::BOLD),
        )));

        for &(idx, a) in agents {
            let status = a.status.as_deref().unwrap_or("idle");
            let (status_icon, status_color) = match status {
                "working" => ("●", Color::Green),
                "thinking" => ("●", Color::Blue),
                "idle" => ("○", Color::DarkGray),
                "error" => ("✗", Color::Red),
                _ => ("·", Color::DarkGray),
            };

            let is_supervisor = a.supervisor.is_none() || a.supervisor.as_deref() == Some("");
            let is_selected = idx == state.agents_selected;
            let bg = if is_selected { Color::Rgb(50, 50, 75) } else { Color::Rgb(20, 20, 30) };
            let indicator = if is_selected { "▸ " } else if is_supervisor { "  " } else { "   " };

            let mut row_spans = vec![
                Span::styled(
                    format!("{}{:<w$}", indicator, a.name, w = col_widths[0]),
                    Style::default().fg(if is_selected { Color::Yellow } else { Color::Cyan }).bg(bg),
                ),
                Span::styled(
                    format!("{:<w$}", a.role.as_deref().unwrap_or("-"), w = col_widths[1]),
                    Style::default().fg(Color::White).bg(bg),
                ),
                Span::styled(
                    format!("{} {:<w$}", status_icon, status, w = col_widths[2] - 2),
                    Style::default().fg(status_color).bg(bg),
                ),
                Span::styled(
                    format!("{:<w$}", a.tasks_completed.unwrap_or(0), w = col_widths[3]),
                    Style::default().fg(Color::Green).bg(bg),
                ),
                Span::styled(
                    format!("{:<w$}", a.tasks_failed.unwrap_or(0), w = col_widths[4]),
                    Style::default().fg(Color::Red).bg(bg),
                ),
                Span::styled(
                    format_tokens(a.tokens_used.unwrap_or(0)),
                    Style::default().fg(Color::White).bg(bg),
                ),
            ];
            // Pad the rest of the line with background
            let used: usize = col_widths.iter().sum::<usize>() + indicator.len();
            let remaining = (chunks[0].width as usize).saturating_sub(used + 6);
            if remaining > 0 {
                row_spans.push(Span::styled(" ".repeat(remaining), Style::default().bg(bg)));
            }

            visual_lines.push(Line::from(row_spans));
        }
    }

    let para = Paragraph::new(visual_lines);
    f.render_widget(para, chunks[0]);

    // Separator
    let sep = "─".repeat(chunks[1].width as usize);
    f.render_widget(
        Paragraph::new(Span::styled(sep, Style::default().fg(Color::Rgb(50, 50, 60)))),
        chunks[1],
    );

    // Detail panel for selected agent
    if let Some(agent) = state.agent_list.get(state.agents_selected) {
        let supervisor = agent.supervisor.as_deref().unwrap_or("none");
        let model = agent.model.as_deref().unwrap_or("default");
        let budget = agent.budget.unwrap_or(0);
        let tokens = agent.tokens_used.unwrap_or(0);
        let budget_pct = if budget > 0 { (tokens as f64 / budget as f64 * 100.0).min(100.0) } else { 0.0 };
        let current = agent.current_task.as_deref().unwrap_or("—");

        let detail_lines = vec![
            Line::from(vec![
                Span::styled("  Agent: ", Style::default().fg(Color::DarkGray)),
                Span::styled(&agent.name, Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
                Span::styled("  Supervisor: ", Style::default().fg(Color::DarkGray)),
                Span::styled(supervisor, Style::default().fg(Color::White)),
                Span::styled("  Model: ", Style::default().fg(Color::DarkGray)),
                Span::styled(model, Style::default().fg(Color::White)),
            ]),
            Line::from(vec![
                Span::styled("  Budget: ", Style::default().fg(Color::DarkGray)),
                Span::styled(
                    format!("{} / {} ({:.0}%)", format_tokens(tokens), format_tokens(budget), budget_pct),
                    Style::default().fg(if budget_pct > 90.0 { Color::Red } else if budget_pct > 70.0 { Color::Yellow } else { Color::Green }),
                ),
            ]),
            Line::from(vec![
                Span::styled("  Current: ", Style::default().fg(Color::DarkGray)),
                Span::styled(current, Style::default().fg(Color::White)),
            ]),
        ];

        f.render_widget(Paragraph::new(detail_lines), chunks[2]);
    }
}

fn draw_config_overlay(f: &mut Frame, area: Rect, state: &AppState) {
    let popup_area = centered_rect(70, 65, area);
    f.render_widget(Clear, popup_area);

    let block = Block::default()
        .title(" Configuration — ESC close ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Yellow))
        .style(Style::default().bg(Color::Rgb(20, 20, 30)));

    let inner = block.inner(popup_area);
    f.render_widget(block, popup_area);

    let mut lines = vec![
        Line::from(vec![
            Span::styled("  Company  ", Style::default().fg(Color::DarkGray)),
            Span::styled(&state.config_company, Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("  Mission  ", Style::default().fg(Color::DarkGray)),
            Span::styled(&state.config_mission, Style::default().fg(Color::White)),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "  Runtime Config",
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
    ];

    for entry in &state.config_entries {
        let value_color = match entry.value.as_str() {
            "true" | "on" | "ON" => Color::Green,
            "false" | "off" | "OFF" => Color::Red,
            _ => Color::White,
        };
        lines.push(Line::from(vec![
            Span::styled(format!("  {:20}", entry.key), Style::default().fg(Color::Cyan)),
            Span::styled(&entry.value, Style::default().fg(value_color)),
        ]));
    }

    f.render_widget(Paragraph::new(lines), inner);
}

fn task_status_style(status: &str) -> (&str, Color) {
    match status {
        "pending" => ("○", Color::Blue),
        "in_progress" => ("◉", Color::Yellow),
        "completed" => ("✓", Color::Green),
        "failed" => ("✗", Color::Red),
        "awaiting_approval" => ("⚠", Color::Magenta),
        "paused" => ("⏸", Color::DarkGray),
        "rejected" => ("✗", Color::Red),
        _ => ("·", Color::DarkGray),
    }
}

fn short_status(status: &str) -> &str {
    match status {
        "pending" => "pending",
        "in_progress" => "running",
        "completed" => "done",
        "failed" => "failed",
        "awaiting_approval" => "approval",
        "paused" => "paused",
        "rejected" => "rejected",
        _ => status,
    }
}

fn truncate_str(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let truncated: String = s.chars().take(max - 1).collect();
        format!("{}…", truncated)
    }
}

fn draw_help_overlay(f: &mut Frame, area: Rect, state: &AppState) {
    let popup_area = centered_rect(60, 60, area);
    f.render_widget(Clear, popup_area);

    let block = Block::default()
        .title(" Help — Press ESC to close ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Yellow))
        .style(Style::default().bg(Color::Rgb(20, 20, 30)));

    let help_text = vec![
        Line::from(Span::styled(
            "Shazam Commands",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  /task ", Style::default().fg(Color::Cyan)),
            Span::raw("Create a task for the PM"),
        ]),
        Line::from(vec![
            Span::styled("  /tasks ", Style::default().fg(Color::Cyan)),
            Span::raw("List tasks (--clear to reset)"),
        ]),
        Line::from(vec![
            Span::styled("  /approve ", Style::default().fg(Color::Cyan)),
            Span::raw("Approve a pending task (--all for batch)"),
        ]),
        Line::from(vec![
            Span::styled("  /aa ", Style::default().fg(Color::Cyan)),
            Span::raw("Approve all pending tasks (shortcut)"),
        ]),
        Line::from(vec![
            Span::styled("  /reject ", Style::default().fg(Color::Cyan)),
            Span::raw("Reject a pending task"),
        ]),
        Line::from(vec![
            Span::styled("  /dashboard ", Style::default().fg(Color::Cyan)),
            Span::raw("Show agent status dashboard"),
        ]),
        Line::from(vec![
            Span::styled("  /config ", Style::default().fg(Color::Cyan)),
            Span::raw("Show current configuration"),
        ]),
        Line::from(vec![
            Span::styled("  /org ", Style::default().fg(Color::Cyan)),
            Span::raw("Show organization tree"),
        ]),
        Line::from(vec![
            Span::styled("  /agents ", Style::default().fg(Color::Cyan)),
            Span::raw("List all agents with status"),
        ]),
        Line::from(vec![
            Span::styled("  /msg ", Style::default().fg(Color::Cyan)),
            Span::raw("Send message to agent (/msg <agent> <text>)"),
        ]),
        Line::from(vec![
            Span::styled("  /auto-approve ", Style::default().fg(Color::Cyan)),
            Span::raw("Toggle auto-approve [on|off]"),
        ]),
        Line::from(vec![
            Span::styled("  /start ", Style::default().fg(Color::Cyan)),
            Span::raw("Start agents"),
        ]),
        Line::from(vec![
            Span::styled("  /stop ", Style::default().fg(Color::Cyan)),
            Span::raw("Stop agents (keep REPL open)"),
        ]),
        Line::from(vec![
            Span::styled("  /resume ", Style::default().fg(Color::Cyan)),
            Span::raw("Resume agents"),
        ]),
        Line::from(vec![
            Span::styled("  /status ", Style::default().fg(Color::Cyan)),
            Span::raw("Show system status"),
        ]),
        Line::from(vec![
            Span::styled("  /clear ", Style::default().fg(Color::Cyan)),
            Span::raw("Clear events"),
        ]),
        Line::from(vec![
            Span::styled("  /help ", Style::default().fg(Color::Cyan)),
            Span::raw("Show this help"),
        ]),
        Line::from(vec![
            Span::styled("  /quit ", Style::default().fg(Color::Cyan)),
            Span::raw("Exit Shazam"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Agent Management",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  /agent add <name> ", Style::default().fg(Color::Cyan)),
            Span::raw("Add new agent (--role, --domain, --supervisor, --budget)"),
        ]),
        Line::from(vec![
            Span::styled("  /agent edit <name> ", Style::default().fg(Color::Cyan)),
            Span::raw("Edit agent (--role, --domain, --budget, --model)"),
        ]),
        Line::from(vec![
            Span::styled("  /agent remove <name> ", Style::default().fg(Color::Cyan)),
            Span::raw("Remove agent"),
        ]),
        Line::from(vec![
            Span::styled("  /agent presets ", Style::default().fg(Color::Cyan)),
            Span::raw("List available agent presets"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Team Templates",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  /team create <domain> ", Style::default().fg(Color::Cyan)),
            Span::raw("Create team (--devs N, --qa N, --designer, --researcher)"),
        ]),
        Line::from(vec![
            Span::styled("  /team templates ", Style::default().fg(Color::Cyan)),
            Span::raw("Show team template help"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Task Actions",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  /pause-task <id> ", Style::default().fg(Color::Cyan)),
            Span::raw("Pause a task"),
        ]),
        Line::from(vec![
            Span::styled("  /resume-task <id> ", Style::default().fg(Color::Cyan)),
            Span::raw("Resume a paused task"),
        ]),
        Line::from(vec![
            Span::styled("  /kill-task <id> ", Style::default().fg(Color::Cyan)),
            Span::raw("Kill running task"),
        ]),
        Line::from(vec![
            Span::styled("  /retry-task <id> ", Style::default().fg(Color::Cyan)),
            Span::raw("Retry failed task"),
        ]),
        Line::from(vec![
            Span::styled("  /delete-task <id> ", Style::default().fg(Color::Cyan)),
            Span::raw("Delete a task"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Keyboard Shortcuts",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from("  ↑/↓       Command history"),
        Line::from("  Tab       Accept ghost text"),
        Line::from("  Ctrl+C    Exit"),
        Line::from("  Ctrl+L    Clear screen"),
        Line::from("  PgUp/Dn   Scroll events"),
        Line::from("  Mouse     Scroll events"),
        Line::from("  Enter     Open action menu (in /tasks)"),
        Line::from("  ESC       Close overlay"),
    ];

    let total_lines = help_text.len();
    let inner_height = block.inner(popup_area).height as usize;

    let paragraph = Paragraph::new(help_text)
        .block(block)
        .wrap(Wrap { trim: false })
        .scroll((state.help_scroll as u16, 0));

    f.render_widget(paragraph, popup_area);

    // Scrollbar for help overlay
    if total_lines > inner_height {
        let mut scrollbar_state = ScrollbarState::new(total_lines.saturating_sub(inner_height))
            .position(state.help_scroll);

        let scrollbar_area = Rect {
            x: popup_area.x + popup_area.width - 1,
            y: popup_area.y + 1,
            width: 1,
            height: popup_area.height.saturating_sub(2),
        };

        f.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_style(Style::default().fg(Color::Yellow))
                .track_style(Style::default().fg(Color::Rgb(40, 40, 50))),
            scrollbar_area,
            &mut scrollbar_state,
        );
    }
}

fn draw_approval_bar(f: &mut Frame, area: Rect, state: &AppState) {
    let count = state.pending_approvals.len();
    let text = if count == 1 {
        let a = &state.pending_approvals[0];
        format!(" ⚠  Task awaiting approval: \"{}\" by {} — /approve or /reject ", a.title, a.agent)
    } else {
        format!(" ⚠  {} tasks awaiting approval — /approve --all or /tasks ", count)
    };

    let bar_area = Rect {
        x: 0,
        y: area.height.saturating_sub(4), // Above input+separator+status
        width: area.width,
        height: 1,
    };

    let bar = Paragraph::new(Line::from(Span::styled(
        text,
        Style::default()
            .fg(Color::Black)
            .bg(Color::Yellow)
            .add_modifier(Modifier::BOLD),
    )));
    f.render_widget(bar, bar_area);
}

fn format_tokens(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        format!("{:.1}M", tokens as f64 / 1_000_000.0)
    } else if tokens >= 1_000 {
        format!("{:.0}k", tokens as f64 / 1_000.0)
    } else {
        format!("{}", tokens)
    }
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}

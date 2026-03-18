/// Application state shared between input handling and rendering.
use std::collections::VecDeque;

use crate::protocol::{AgentInfo, ApprovalMsg, ConfigEntry, DashboardAgent, StatusMsg, TaskItem};

pub const MAX_EVENTS: usize = 500;

#[derive(Debug, Clone)]
pub struct EventLine {
    pub timestamp: String,
    pub agent: String,
    pub icon: String,
    pub text: String,
    pub color: EventColor,
}

#[derive(Debug, Clone, Copy)]
pub enum EventColor {
    Blue,
    Yellow,
    Green,
    Red,
    Cyan,
    Magenta,
    Gray,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum View {
    Main,
    Dashboard,
    Help,
    Tasks,
    Agents,
    Config,
}

pub struct AppState {
    // Input
    pub input: String,
    pub cursor_pos: usize,
    pub ghost_text: String,
    pub input_history: Vec<String>,
    pub history_index: Option<usize>,

    // Events scroll region
    pub events: VecDeque<EventLine>,
    pub scroll_offset: usize, // 0 = bottom (latest)

    // Status bar
    pub status: StatusMsg,

    // Overlays
    pub view: View,
    pub dashboard_agents: Vec<DashboardAgent>,

    // Help overlay scroll
    pub help_scroll: usize,

    // Agents overlay
    pub agent_list: Vec<AgentInfo>,
    pub agents_selected: usize,

    // Config overlay
    pub config_company: String,
    pub config_mission: String,
    pub config_entries: Vec<ConfigEntry>,

    // Tasks overlay
    pub task_items: Vec<TaskItem>,
    pub tasks_scroll: usize,
    pub tasks_selected: usize,
    pub task_action_menu: bool,       // true when action submenu is open
    pub task_action_selected: usize,  // selected action index

    // Approval queue
    pub pending_approvals: Vec<ApprovalMsg>,

    // Paste state
    pub paste_count: usize,
    pub image_count: usize,
    pub attachments: Vec<Attachment>,

    // Running flag
    pub running: bool,
}

#[derive(Debug, Clone)]
pub enum Attachment {
    Paste { id: usize, content: String, lines: usize },
    Image { id: usize, path: String },
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            input: String::new(),
            cursor_pos: 0,
            ghost_text: String::new(),
            input_history: Vec::new(),
            history_index: None,
            events: VecDeque::with_capacity(MAX_EVENTS),
            scroll_offset: 0,
            status: StatusMsg {
                company: None,
                status: Some("idle".into()),
                agents_total: Some(0),
                agents_active: Some(0),
                tasks_pending: Some(0),
                tasks_running: Some(0),
                tasks_done: Some(0),
                tasks_awaiting: Some(0),
                budget_used: Some(0),
                budget_total: Some(0),
            },
            help_scroll: 0,
            agent_list: Vec::new(),
            agents_selected: 0,
            config_company: String::new(),
            config_mission: String::new(),
            config_entries: Vec::new(),
            task_items: Vec::new(),
            tasks_scroll: 0,
            tasks_selected: 0,
            task_action_menu: false,
            task_action_selected: 0,
            view: View::Main,
            dashboard_agents: Vec::new(),
            pending_approvals: Vec::new(),
            paste_count: 0,
            image_count: 0,
            attachments: Vec::new(),
            running: true,
        }
    }
}

impl AppState {
    pub fn push_event(&mut self, event: EventLine) {
        if self.events.len() >= MAX_EVENTS {
            self.events.pop_front();
        }
        // If user was scrolled up, adjust offset to keep position
        if self.scroll_offset > 0 {
            self.scroll_offset += 1;
        }
        self.events.push_back(event);
    }

    pub fn add_paste(&mut self, content: String) -> usize {
        self.paste_count += 1;
        let id = self.paste_count;
        let lines = content.lines().count();
        self.attachments.push(Attachment::Paste { id, content, lines });
        id
    }

    pub fn add_image(&mut self, path: String) -> usize {
        self.image_count += 1;
        let id = self.image_count;
        self.attachments.push(Attachment::Image { id, path });
        id
    }

    pub fn clear_attachments(&mut self) {
        self.attachments.clear();
    }

    pub fn submit_input(&mut self) -> String {
        let cmd = self.input.clone();
        if !cmd.trim().is_empty() {
            self.input_history.push(cmd.clone());
        }
        self.input.clear();
        self.cursor_pos = 0;
        self.ghost_text.clear();
        self.history_index = None;
        self.scroll_offset = 0;
        cmd
    }

    pub fn history_up(&mut self) {
        if self.input_history.is_empty() {
            return;
        }
        let idx = match self.history_index {
            None => self.input_history.len().saturating_sub(1),
            Some(i) => i.saturating_sub(1),
        };
        self.history_index = Some(idx);
        self.input = self.input_history[idx].clone();
        self.cursor_pos = self.input.chars().count();
    }

    pub fn history_down(&mut self) {
        match self.history_index {
            None => {}
            Some(i) => {
                if i + 1 >= self.input_history.len() {
                    self.history_index = None;
                    self.input.clear();
                    self.cursor_pos = 0;
                } else {
                    let idx = i + 1;
                    self.history_index = Some(idx);
                    self.input = self.input_history[idx].clone();
                    self.cursor_pos = self.input.chars().count();
                }
            }
        }
    }
}

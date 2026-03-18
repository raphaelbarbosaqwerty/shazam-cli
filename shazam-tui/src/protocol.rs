/// JSON protocol types for Elixir ↔ Rust communication.
///
/// Elixir → Rust (render commands):
///   event, status, dashboard, approval, clear, quit
///
/// Rust → Elixir (user input):
///   command, paste, image, key, resize
use serde::{Deserialize, Serialize};

// ── Messages FROM Elixir ──────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
pub enum InboundMsg {
    Event(EventMsg),
    Status(StatusMsg),
    Dashboard(DashboardMsg),
    TaskList(TaskListMsg),
    AgentList(AgentListMsg),
    ConfigInfo(ConfigInfoMsg),
    Approval(ApprovalMsg),
    Clear,
    ClearApprovals,
    Quit,
    GhostText(GhostTextMsg),
}

#[derive(Debug, Deserialize)]
pub struct EventMsg {
    pub timestamp: Option<String>,
    pub agent: Option<String>,
    pub event: String,
    pub title: Option<String>,
    pub text: Option<String>,
    pub assigned_to: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct StatusMsg {
    pub company: Option<String>,
    pub status: Option<String>,      // "running" | "paused" | "idle"
    pub agents_total: Option<u32>,
    pub agents_active: Option<u32>,
    pub tasks_pending: Option<u32>,
    pub tasks_running: Option<u32>,
    pub tasks_done: Option<u32>,
    pub tasks_awaiting: Option<u32>,
    pub budget_used: Option<u64>,
    pub budget_total: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct DashboardMsg {
    pub agents: Vec<DashboardAgent>,
}

#[derive(Debug, Deserialize)]
pub struct DashboardAgent {
    pub name: String,
    pub role: Option<String>,
    pub status: Option<String>,
    pub domain: Option<String>,
    pub supervisor: Option<String>,
    pub tasks_completed: Option<u32>,
    pub tasks_failed: Option<u32>,
    pub tokens_used: Option<u64>,
    pub budget: Option<u64>,
    pub current_task: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TaskListMsg {
    pub tasks: Vec<TaskItem>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TaskItem {
    pub id: String,
    pub title: String,
    pub status: String,
    pub assigned_to: Option<String>,
    pub created_by: Option<String>,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentInfo {
    pub name: String,
    pub role: Option<String>,
    pub domain: Option<String>,
    pub supervisor: Option<String>,
    pub status: Option<String>,
    pub tasks_completed: Option<u32>,
    pub tasks_failed: Option<u32>,
    pub tokens_used: Option<u64>,
    pub budget: Option<u64>,
    pub current_task: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AgentListMsg {
    pub agents: Vec<AgentInfo>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConfigEntry {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Deserialize)]
pub struct ConfigInfoMsg {
    pub company: String,
    pub mission: String,
    pub entries: Vec<ConfigEntry>,
}

#[derive(Debug, Deserialize)]
pub struct ApprovalMsg {
    pub task_id: String,
    pub title: String,
    pub agent: String,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct GhostTextMsg {
    pub text: String,
}

// ── Messages TO Elixir ────────────────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
pub enum OutboundMsg {
    Command(CommandMsg),
    Paste(PasteMsg),
    Image(ImageMsg),
    Key(KeyMsg),
    Resize(ResizeMsg),
}

#[derive(Debug, Serialize)]
pub struct CommandMsg {
    pub raw: String,
}

#[derive(Debug, Serialize)]
pub struct PasteMsg {
    pub content: String,
    pub line_count: usize,
}

#[derive(Debug, Serialize)]
pub struct ImageMsg {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct KeyMsg {
    pub key: String,
}

#[derive(Debug, Serialize)]
pub struct ResizeMsg {
    pub cols: u16,
    pub rows: u16,
}

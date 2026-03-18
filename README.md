# Shazam

**Autonomous AI agent teams, right from your terminal.**

Shazam is an open-source CLI that orchestrates teams of Claude AI agents. You describe what you want built. A PM agent breaks it down, assigns subtasks to developer agents, and they execute — all while you watch in a real-time TUI dashboard.

```
shazam❯ Build a REST API for user authentication with JWT tokens
  22:15:03 [pm]        Created: Build a REST API for user authentication...
  22:15:08 [pm]        Started: task_1
  22:15:14 [pm]        Completed: task_1
  22:15:14 [senior_1]  Started: Implement JWT middleware and token validation
  22:15:14 [senior_2]  Started: Create user registration and login endpoints
  22:15:14 [qa_1]      Started: Write authentication test suite
```

**Website:** [shazam.dev](https://shazam.dev) | **Docs:** [shazam.dev/docs](https://shazam.dev/docs) | **License:** MIT

![Shazam Demo](docs/images/demo.gif)

---

## Why Shazam?

- **Natural language in, working code out.** Type what you want. The PM breaks it down. Developers implement. QA tests.
- **Human-in-the-loop.** Every subtask needs your approval before agents execute. You stay in control.
- **Real-time TUI.** Watch agents work in a beautiful terminal interface with scrollable events, task management, and agent dashboards.
- **Team templates.** Spin up a backend team with `/team create backend --devs 2 --qa 1` in one command.
- **Session pooling.** Agents reuse Claude sessions across tasks — saves tokens and preserves context.
- **Open source.** Built with Elixir/OTP for fault-tolerance and a Rust TUI for performance.

---

## How It Works

```
You (CEO) ──> describe task in natural language
                │
           PM Agent (Haiku) ──> breaks down into subtasks
                │
     ┌──────────┼──────────┐
     │          │          │
 Dev Agent   Dev Agent   QA Agent
 (Opus)      (Sonnet)    (Sonnet)
 implements  implements  writes tests
```

1. You type a task in the interactive shell
2. The PM agent decomposes it into subtasks with dependencies
3. Subtasks go to your approval queue (or auto-approve)
4. Developer agents execute in parallel, respecting module locks
5. QA agents validate the output
6. You review results in the TUI

---

## Features

| Feature | Description |
|---|---|
| **Interactive TUI** | Rust-powered terminal with overlays for tasks, agents, config, dashboard |
| **Ghost text autocomplete** | Tab-completable `/commands` with inline hints |
| **Task action menu** | Select a task, press Enter, approve/reject/pause/kill/retry |
| **Agent management** | `/agent add`, `/agent edit`, `/agent remove` with YAML persistence |
| **Team templates** | `/team create <domain> --devs N --qa N` creates entire teams |
| **10 agent presets** | PM, Senior Dev, Junior Dev, QA, Designer, Researcher, DevOps, Writer, Market Analyst, Competitor Analyst |
| **Session pooling** | Reuses Claude sessions (recycles after 8 tasks or 15 min idle) |
| **Module locking** | Prevents concurrent edits to the same file |
| **Peer reassignment** | Idle agents pick up tasks from busy peers |
| **Auto-retry** | Exponential backoff (5s, 15s, 30s) for failed tasks |
| **Human-in-the-loop** | PM subtasks require approval before execution |
| **Real-time events** | Live feed of agent activity with scrollbar and mouse support |
| **REST API** | HTTP endpoints + WebSocket for external integrations |

---

## Architecture

```
                          +---------------+
                          |   YOU (CEO)   |
                          |  Human-in-    |
                          |  the-Loop     |
                          +-------+-------+
                                  |
                           Creates tasks &
                           approves outputs
                                  |
                 +----------------+----------------+
                 |                |                |
          +------v------+  +-----v------+  +------v------+
          | PM Dev Team  |  | PM Analysts |  |  PM Design  |
          | (Haiku 4.5)  |  | (Haiku 4.5) |  | (Haiku 4.5) |
          +------+-------+  +-----+------+  +-------------+
                 |                 |
      +------+--+--+        +-----+-----+
      |      |     |        |           |
   +--v--++--v-++--v--+  +--v----+  +---v----+
   | Dev  || Dev|| QA  |  |Market |  |Compet. |
   | Sr.  || Jr.||     |  |Analyst|  |Analyst |
   +------++----++-----+  +------+   +--------+
   Opus/   Sonnet Sonnet   Sonnet     Sonnet
   Sonnet
```

### OTP Supervision Tree

```
Shazam.Supervisor (one_for_one)
  |- Registry (CompanyRegistry)
  |- Registry (RalphLoopRegistry)
  |- DynamicSupervisor (AgentSupervisor)
  |- DynamicSupervisor (CompanySupervisor)
  |- DynamicSupervisor (RalphLoopSupervisor)
  |- Shazam.TaskBoard (GenServer, ETS-backed)
  |- Shazam.SessionPool (GenServer)
  |- Shazam.API.EventBus (GenServer)
  |- Shazam.Metrics (GenServer)
  |- Shazam.AgentInbox (GenServer)
  +- Bandit HTTP Server (port 4040)
```

### Task Execution Flow

```
RalphLoop polls TaskBoard every 5s
  -> TaskScheduler selects best pending task + agent
    -> TaskExecutor builds prompt (memory, skills, role rules)
      -> SessionPool.checkout() gets reused Claude session
        -> Orchestrator.execute_on_session() runs on Claude
          -> SubtaskParser extracts subtasks from output
            -> New subtasks created (pending or awaiting_approval)
              -> TaskBoard.complete() marks original task done
```

### Role Separation

| Role | Can Do | Cannot Do |
|---|---|---|
| **PM** | Delegate, break down tasks, coordinate | Read code, use dev tools |
| **Dev** | Implement features, fix bugs, refactor | Write tests |
| **QA** | Write tests, report bugs, validate | Implement features |
| **Analyst** | Research, analyze data, report | Write code |

---

## Installation

### Quick Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

The setup script automatically detects your environment:
- **If Nix is installed** → uses Nix for all dependencies (easiest, recommended)
- **If Nix is not installed** → checks for Elixir, Rust, and Claude Code manually

### Recommended: Install with Nix (zero dependency hassle)

If you don't have Elixir or Rust installed, Nix is the fastest path. It provides everything automatically:

```bash
# 1. Install Nix (one-time, takes ~2 minutes)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh

# 2. Install Shazam (Nix handles Elixir, Rust, SQLite for you)
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

### Without Nix (manual prerequisites)

If you prefer not to use Nix, install these first:

- **Elixir** >= 1.16 and **Erlang/OTP** >= 26 ([install](https://elixir-lang.org/install.html))
- **Rust** ([install](https://rustup.rs/))
- **Claude Code** installed and logged in ([install](https://docs.anthropic.com/en/docs/claude-code))

Then run the same setup command:

```bash
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

> **macOS note:** Apple ships `/usr/bin/shazam` (ShazamKit). If there's a conflict, use `shz` instead — it's installed automatically as an alias:
> ```bash
> shz init
> shz shell
> ```

---

## Quick Start

### 1. Initialize a Project

```bash
shazam init
```

This creates a `shazam.yaml` in the current directory with a starter company configuration.

### 2. Configure Your Team

Edit `shazam.yaml` (see [Configuration](#configuration) below).

### 3. Start the Interactive Shell

```bash
shazam shell
```

This opens the Rust TUI with the full interactive shell. Inside:

```
shazam❯ /start                    # Boot agents and RalphLoop
shazam❯ /tasks                    # View task board
shazam❯ Build user authentication # Creates task for PM (natural language)
shazam❯ /aa                       # Approve all pending subtasks
shazam❯ /dashboard                # Live agent status
shazam❯ /agents                   # View agents by domain
```

### Alternative: CLI Commands

```bash
# Start server mode (HTTP API on port 4040)
shazam start

# Create a task
shazam task "Implement JWT auth" --to pm

# Monitor
shazam logs
shazam dashboard
shazam org
```

### Programmatic Usage (Elixir)

```elixir
# Direct parallel execution
agents = [
  %{name: "researcher", role: "analyst", prompt: "Research auth best practices"},
  %{name: "implementer", role: "developer", prompt: "Implement JWT auth"}
]
results = Shazam.run(agents)

# Start a full company
Shazam.start_company(%{
  name: "AuthTeam",
  mission: "Build authentication system",
  agents: [
    %{name: "pm", role: "Project Manager", supervisor: nil},
    %{name: "dev", role: "Senior Developer", supervisor: "pm"},
    %{name: "qa", role: "QA Engineer", supervisor: "pm"}
  ]
})

# Assign task
Shazam.assign("AuthTeam", "pm", "Implement JWT authentication")
```

---

## Configuration

Shazam is configured via `shazam.yaml` (or `.shazam/shazam.yaml`).

### Full Configuration Reference

```yaml
# Company definition
company:
  name: "MyTeam"
  mission: "Build and maintain the core product"
  workspace: "/path/to/project"  # Optional, defaults to CWD

# Domain access restrictions (optional)
domains:
  backend:
    description: "Backend services and API"
    paths:
      - "lib/"
      - "src/"
  frontend:
    description: "Frontend application"
    paths:
      - "app/"
      - "components/"

# Agent definitions
agents:
  pm:
    role: "Project Manager"
    # supervisor: null (top of hierarchy)
    budget: 200000                          # Token budget
    model: "claude-haiku-4-5-20251001"      # AI model
    tools:                                  # Allowed tools
      - "Read"
      - "Grep"
      - "WebSearch"
    system_prompt: "You are a PM..."        # Custom prompt (optional)
    domain: "backend"                       # Restrict to domain paths
    heartbeat_interval: 60000               # Health check interval (ms)

  senior_dev:
    role: "Senior Developer"
    supervisor: "pm"                        # Reports to PM
    budget: 150000
    tools:
      - "Read"
      - "Edit"
      - "Write"
      - "Bash"
      - "Grep"
      - "Glob"
    domain: "backend"

  qa:
    role: "QA Engineer"
    supervisor: "pm"
    budget: 100000

# RalphLoop configuration
config:
  auto_approve: false       # true = subtasks execute immediately
                            # false = subtasks go to approval queue
  auto_retry: true          # Retry failed tasks automatically
  max_concurrent: 4         # Max parallel agent executions
  max_retries: 2            # Retry attempts before giving up
  poll_interval: 5000       # Task polling interval (ms)
  module_lock: true         # Prevent concurrent edits to same file
  peer_reassign: true       # Assign to idle peers if agent is busy
```

### Default Tool Sets by Role

| Role | Default Tools |
|---|---|
| Manager/PM | Read, Grep, Glob, WebSearch |
| Developer | Read, Edit, Write, Bash, Grep, Glob |
| QA | Read, Edit, Write, Bash, Grep, Glob |
| Analyst | Read, Grep, WebSearch, WebFetch |

### Default Values

| Setting | Default |
|---|---|
| Budget | 100,000 tokens |
| Heartbeat interval | 60,000 ms |
| Poll interval | 5,000 ms |
| Max concurrent | 4 |
| Max retries | 2 |
| HTTP port | 4040 |

---

## CLI Reference

```
USAGE: shazam <command> [options]
```

| Command | Description | Key Flags |
|---|---|---|
| `init` | Create a new `shazam.yaml` configuration | — |
| `start` | Boot server from YAML config | `-p/--port`, `-f/--file`, `--no-resume` |
| `shell` | Interactive REPL terminal | `-p/--port`, `-f/--file` |
| `status` | Show running companies and agents | `-c/--company`, `-p/--port` |
| `stop` | Stop a company | `-c/--company`, `-p/--port`, `--all` |
| `task "title"` | Create a task | `--to agent`, `-c/--company`, `-p/--port` |
| `org` | Display org chart | `-c/--company`, `-p/--port` |
| `logs [agent]` | Stream live events | `-c/--company`, `-p/--port` |
| `agent add <name>` | Add agent to running company | `--role`, `--supervisor`, `--domain`, `--budget`, `--model` |
| `apply` | Apply YAML config changes to running system | `-f/--file`, `-p/--port` |
| `dashboard` | Interactive TUI dashboard | `-c/--company`, `-p/--port` |
| `version` | Show version | — |
| `update` | Check for updates | — |
| `help` | Show help | — |

### Examples

```bash
# Start with custom port and config file
shazam start -p 5000 -f my-team.yaml

# Create a task assigned to a specific agent
shazam task "Fix the login bug" --to senior_dev -c MyTeam

# Stop all companies
shazam stop --all

# Add an agent dynamically
shazam agent add designer --role "UI Designer" --supervisor pm --budget 80000

# Apply updated YAML without restarting
shazam apply -f shazam.yaml
```

### Interactive Shell Commands

When running `shazam shell`, the following `/commands` are available:

| Command | Description |
|---|---|
| `/start` | Start agents |
| `/stop` | Stop agents (keep REPL open) |
| `/pause` | Pause RalphLoop |
| `/resume` | Resume RalphLoop |
| `/dashboard` | Agent progress dashboard |
| `/status` | Company and agent overview |
| `/agents` | List all agents with status |
| `/org` | Show org chart |
| `/tasks` | List tasks (`--clear` to reset) |
| `/task <title>` | Create a new task (`--to agent`) |
| `/approve [id]` | Approve pending task (`--all` for batch) |
| `/aa` | Approve all pending tasks (shortcut) |
| `/reject <id>` | Reject a pending task |
| `/msg <agent> <msg>` | Send message to agent |
| `/auto-approve` | Toggle auto-approve (`on`/`off`) |
| `/config` | Show current configuration |
| `/agent add <name>` | Add new agent (`--role`, `--domain`, `--supervisor`, `--budget`) |
| `/agent edit <name>` | Edit agent (`--role`, `--domain`, `--budget`, `--model`) |
| `/agent remove <name>` | Remove agent |
| `/pause-task <id>` | Pause a task |
| `/resume-task <id>` | Resume a paused task |
| `/kill-task <id>` | Kill running task |
| `/retry-task <id>` | Retry failed task |
| `/delete-task <id>` | Delete a task |
| `/clear` | Clear scroll region |
| `/help` | Show help |
| `/quit` | Exit Shazam |

**Keyboard shortcuts:** `↑/↓` command history, `Tab` accept ghost text, `PgUp/PgDn` or mouse scroll events, `Enter` open action menu in `/tasks`, `Ctrl+C` exit, `ESC` close overlay.

---

## API Reference

Shazam exposes a REST API on port 4040 (configurable).

### Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/companies` | List all running companies |
| `POST` | `/api/companies` | Create a new company |
| `GET` | `/api/companies/:name/agents` | List agents in a company |
| `PUT` | `/api/companies/:name/agents` | Update agents configuration |
| `GET` | `/api/companies/:name/org-chart` | Get organizational chart |
| `POST` | `/api/companies/:name/tasks` | Create a task in a company |
| `GET` | `/api/tasks` | List tasks (supports filters) |
| `GET` | `/api/events/recent` | Get recent events |

### WebSocket

Connect to `ws://localhost:4040/ws` for real-time event streaming. Events include:

- Agent text output (deltas and complete)
- Tool usage notifications
- Task status changes
- System events

---

## Core Concepts

### Companies

A **company** is a self-contained unit with its own hierarchy of agents, task board, and execution loop. Multiple companies can run simultaneously, each managing independent workstreams.

### RalphLoop

The **RalphLoop** is the heart of each company. It continuously polls the TaskBoard for pending tasks, selects the best agent for each task, executes it, and processes the output (including subtask creation). Configuration options:

- **auto_approve** — Skip approval queue for PM-created subtasks
- **max_concurrent** — Limit parallel executions
- **poll_interval** — How often to check for new tasks
- **module_lock** — Prevent concurrent edits to the same file
- **peer_reassign** — Redistribute work to idle agents

### Session Pool

The **SessionPool** maintains reusable Claude Code sessions per agent. This preserves context across tasks and significantly reduces token usage. Sessions are automatically recycled after 8 tasks or 15 minutes of inactivity.

### Task Lifecycle

```
pending -> in_progress -> completed
                       -> failed (-> retry -> pending)
                       -> awaiting_approval -> approved -> pending
                                            -> rejected
```

Tasks support: creation, atomic checkout, completion, failure, retry, pause/resume, reassignment, soft delete, and hard purge.

### Subtask Delegation

When a PM agent outputs a JSON block with subtasks, the SubtaskParser automatically creates child tasks:

```json
[
  {"title": "Implement auth middleware", "assigned_to": "senior_dev", "depends_on": null},
  {"title": "Write auth tests", "assigned_to": "qa", "depends_on": "Implement auth middleware"}
]
```

### Human-in-the-Loop

When `auto_approve: false`, PM-generated subtasks enter an `awaiting_approval` state. The user must approve or reject each subtask before it executes. This provides oversight over the AI delegation chain.

### Module Locking

The ModuleManager prevents multiple agents from editing the same file simultaneously. When an agent checks out a task that touches specific modules, those modules are locked until the task completes.

### Codex Fallback

If Claude hits rate limits, Shazam can fall back to GPT-5-Codex via the Codex CLI. Configure via environment variables:

```bash
export CODEX_FALLBACK_MODEL="gpt-5-codex"
export CODEX_CLI_BIN="codex"
```

---

## Module Reference

### Core Modules (`lib/shazam/`)

| Module | File | Description |
|---|---|---|
| `Shazam` | `lib/shazam.ex` | Public API — `run/2`, `pipeline/2`, `start_company/1`, `assign/3` |
| `Shazam.Application` | `application.ex` | OTP supervision tree bootstrap |
| `Shazam.Company` | `company.ex` | GenServer managing agent hierarchy, tasks, org chart |
| `Shazam.Orchestrator` | `orchestrator.ex` | Parallel/pipeline agent execution via Claude Code |
| `Shazam.RalphLoop` | `ralph_loop.ex` | Per-company task polling and execution loop |

### Task System

| Module | File | Description |
|---|---|---|
| `Shazam.TaskBoard` | `task_board.ex` | ETS-backed task CRUD with atomic checkout |
| `Shazam.TaskScheduler` | `task_scheduler.ex` | Task selection, peer reassignment, module locking |
| `Shazam.TaskExecutor` | `task_executor.ex` | Prompt building, session management, execution |
| `Shazam.SubtaskParser` | `subtask_parser.ex` | Extract subtasks from agent output |
| `Shazam.TaskTemplates` | `task_templates.ex` | Pre-built prompt templates |
| `Shazam.RetryPolicy` | `retry_policy.ex` | Exponential backoff for failed tasks |

### Agent & Organization

| Module | File | Description |
|---|---|---|
| `Shazam.AgentWorker` | `agent_worker.ex` | Agent configuration struct |
| `Shazam.AgentPresets` | `agent_presets.ex` | Pre-configured role templates |
| `Shazam.AgentInbox` | `agent_inbox.ex` | Per-agent message queue |
| `Shazam.Hierarchy` | `hierarchy.ex` | Org chart, cycle detection (Kahn's algorithm) |
| `Shazam.ModuleManager` | `module_manager.ex` | File-level access control per domain |

### Session & Persistence

| Module | File | Description |
|---|---|---|
| `Shazam.SessionPool` | `session_pool.ex` | Reusable Claude Code session management |
| `Shazam.Store` | `store.ex` | Persistence abstraction (SQLite or JSON fallback) |
| `Shazam.Repo` | `repo.ex` | SQLite interface (WAL mode, KV store) |

### Memory

| Module | File | Description |
|---|---|---|
| `Shazam.MemoryBank` | `memory_bank.ex` | Per-agent markdown memory files |
| `Shazam.SkillMemory` | `skill_memory.ex` | Structured skill-graph knowledge system |

### API & CLI

| Module | File | Description |
|---|---|---|
| `Shazam.API.Router` | `api/router.ex` | REST API endpoint handlers |
| `Shazam.API.EventBus` | `api/event_bus.ex` | Real-time event pub/sub broadcasting |
| `Shazam.API.WebSocket` | `api/websocket.ex` | WebSocket connection handler |
| `Shazam.CLI` | `cli.ex` | Command-line interface entry point |
| `Shazam.CLI.REPL` | `cli/repl.ex` | Interactive shell with command history |
| `Shazam.CLI.YamlParser` | `cli/yaml_parser.ex` | shazam.yaml parsing and validation |
| `Shazam.CLI.Formatter` | `cli/formatter.ex` | Terminal output formatting (colors, tables) |

### Infrastructure

| Module | File | Description |
|---|---|---|
| `Shazam.Metrics` | `metrics.ex` | Token usage and performance tracking |
| `Shazam.FileLogger` | `file_logger.ex` | File-based logging |

---

## Memory Systems

Shazam has two complementary memory systems:

### MemoryBank (Legacy)

Per-agent markdown files at `.shazam/memory/{agent_name}.md`. Each file is capped at ~8,000 characters and contains:

- Project Overview
- Architecture & Patterns
- Agent Responsibilities
- Lessons Learned
- Dependencies

### SkillMemory (Current)

A structured skill-graph system at `.shazam/memories/` with YAML frontmatter:

```
.shazam/memories/
  |- SKILL.md              # Root skill index
  |- project/              # Project-wide knowledge
  |    |- overview.md
  |    |- architecture.md
  |    +- conventions.md
  |- agents/               # Per-agent context
  |    |- pm.md
  |    +- senior_dev.md
  |- rules/                # Domain rules
  |    |- testing.md
  |    +- git-workflow.md
  +- decisions/            # Architectural Decision Records
       +- 001-auth-strategy.md
```

Each skill file uses frontmatter:

```markdown
---
name: skill-name
description: One line description
tags: tag1, tag2
---
Content here. Reference other skills: [./rules/testing.md](./rules/testing.md)
```

---

## Persistence

Shazam automatically selects the best available storage backend:

| Backend | Condition | Storage Location |
|---|---|---|
| **SQLite** (primary) | Exqlite available | `.shazam/shazam.db` |
| **JSON** (fallback) | SQLite unavailable | `~/.shazam/{key}.json` |

### Persisted Data

- **Workspace path** — Current working directory
- **Company configs** — Agents, hierarchy, mission, domain config (`company:{name}`)
- **Tasks** — Full task board per company (`tasks:{company}`)

All data is restored on startup. Companies and their RalphLoops resume automatically.

---

## Contributing

### Development Setup

The recommended way to set up a development environment is with Nix:

```bash
# Clone and enter
git clone https://github.com/raphaelbarbosaqwerty/shazam-cli.git
cd shazam-cli

# Option A: Use Nix (recommended — provides all dependencies automatically)
nix develop

# Option B: Manual setup (install Elixir, Erlang, and Rust yourself)
# See Prerequisites section above

# Install deps
mix deps.get

# Run tests
mix test

# Start in development
iex -S mix
```

### Project Structure

```
lib/
  shazam.ex              # Public API
  shazam/
    api/                 # HTTP API, WebSocket, EventBus
    cli/                 # CLI, REPL, YAML parser, formatter
    application.ex       # OTP supervision tree
    company.ex           # Company GenServer
    orchestrator.ex      # Agent execution engine
    ralph_loop.ex        # Task execution loop
    task_board.ex        # Task management (ETS)
    task_executor.ex     # Prompt building & execution
    session_pool.ex      # Session reuse
    ...
config/
  config.exs             # Application configuration
test/
  ...
```

### Code Style

- Follow standard Elixir conventions
- Format code with `mix format`
- Use module docs (`@moduledoc`) for all public modules
- Use typespecs for public functions

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CODEX_FALLBACK_MODEL` | `gpt-5-codex` | Fallback model when Claude is rate-limited |
| `CODEX_CLI_BIN` | `codex` | Path to Codex CLI binary |

---

## Agent Presets

Shazam includes pre-configured agent templates for common roles:

| Preset | Role | Default Model | Use Case |
|---|---|---|---|
| `pm` | Project Manager | Haiku 4.5 | Task delegation and coordination |
| `senior_dev` | Senior Developer | Opus/Sonnet | Complex implementation and architecture |
| `junior_dev` | Junior Developer | Sonnet | Straightforward implementation |
| `qa` | QA Engineer | Sonnet | Testing and bug reporting |
| `researcher` | Researcher | Sonnet | Information gathering and analysis |
| `designer` | UI Designer | Sonnet | Interface design and prototyping |
| `devops` | DevOps Engineer | Sonnet | Infrastructure and deployment |
| `writer` | Technical Writer | Sonnet | Documentation |
| `market_analyst` | Market Analyst | Sonnet | Market research |
| `competitor_analyst` | Competitor Analyst | Sonnet | Competitive analysis |

### Team Templates

Quickly create entire teams with one command:

```bash
# Create a backend team: 2 devs + 1 QA
/team create backend --devs 2 --qa 1

# Create a frontend team: 3 devs + designer
/team create frontend --devs 3 --designer

# Create a research team: 2 devs + researcher
/team create api --devs 2 --researcher
```

---

## Tech Stack

| Component | Technology |
|---|---|
| **Runtime** | Elixir/OTP (GenServer, ETS, DynamicSupervisor) |
| **AI Engine** | Claude Code SDK (`claude_code` ~> 0.29) |
| **HTTP Server** | Bandit (~> 1.0) + Plug (~> 1.16) |
| **WebSocket** | websock_adapter (~> 0.5) |
| **Database** | SQLite via Exqlite (~> 0.27) |
| **Config Parsing** | YamlElixir (~> 2.9) |
| **JSON** | Jason (~> 1.4) |
| **CORS** | CorsPlug (~> 3.0) |
| **TUI** | Rust (ratatui + crossterm) |

---

## License

See [LICENSE](LICENSE) for details.

# Changelog

## v0.3.0 (2026-03-19)

### Features
- **File mentions** — type `@path/to/file` in tasks to auto-expand file contents inline
- **Image paste** — paste image paths into tasks, auto-copied to `.shazam/attachments/`
- **Token tracking** — real-time token usage and cost ($) per agent, persisted across sessions
- **`/memory`** shows per-agent token breakdown and cumulative cost
- **Auto-start** — agents boot automatically when opening shazam (no `/start` needed)
- **Unlimited budget** — omit `budget:` from YAML for no token limit
- **Task preservation** — tasks never deleted from disk, restored on session start
- **Subtask persistence** — PM-created subtasks now saved as `.md` files
- **Agent sync** — new agents synced to Company GenServer immediately
- **Task skip feedback** — shows why tasks aren't picked up (agent not found, budget exceeded)

### Bug Fixes
- **Clean exit** — `/quit` exits with `System.halt(0)`, single message, no orphan processes
- **Tasks stuck in pending** — fixed agent name matching (atom vs string), legacy tasks without company
- **Session crash prevention** — bulletproof loop, safe RalphLoop calls, ignore normal EXIT signals
- **Subtasks not saved** — `create_awaiting` now writes `.md` files

### Test Suite
- **322 tests, 0 failures**
- New: agent_config_test (18), task_files_test (17), pr_reviewer_test (11)
- Updated: metrics_test (+7), yaml_parser_test (+14)
- CI: Elixir 1.18, random port for tests, no conflicts

## v0.2.0 (2026-03-19)

### Features
- **PR Reviewer agent** — review PRs with full codebase context using Opus 4.6
  - `/review <pr>` — AI-powered code review
  - `/review --post <task_id>` — post review to GitHub with inline comments and suggested changes
  - `/review --check <pr>` — verify if review comments were addressed
  - `/review --resolve <pr>` — resolve all conversation threads
  - `/review --learn` — learn review patterns from team's past reviews
  - Comment conventions: blocker, nit, suggestion, question, praise, thought, todo
  - GitHub suggested changes with one-click Apply button
  - Multi-line comments and file-level observations

- **Editable agent configs** — `.shazam/agents/*.md` files replace hardcoded prompts
  - `shazam init` creates `.md` files from presets
  - `/agents --init` generates configs for existing projects
  - `config:` field in YAML to point agents to custom `.md` files
  - Multiple agents can share the same config file

- **Multi-repo workspaces** — agents work across multiple repositories
  - `workspaces:` section in YAML with path for each repo
  - Agents with `workspace:` field run in their respective repo directory
  - `/workspaces` command shows configured repos with path validation

- **Markdown task files** — tasks persist as `.md` in `.shazam/tasks/`
  - Auto-sync on create, checkout, complete, fail, delete
  - `/tasks --sync` imports tasks from files
  - `/tasks --export` exports tasks to files
  - Bulk task creation by adding `.md` files manually

- **Memory monitoring** — `/memory` command + `Mem: MB` in status bar
  - Real-time BEAM memory in status bar (green/yellow/red)
  - Detailed breakdown: processes, ETS, binary, atoms, system

- **Task search and export**
  - `/search <query>` — filter tasks by title
  - `/export [file]` — export tasks to markdown report

- **Task detail view** — select task in `/tasks` to see full result output

- **Persistent command history** — saved across sessions in `~/.shazam/tui_history`

- **Multi-project isolation** — each project gets isolated tasks, agents, metrics

- **Agent visibility** — see tool_use and text events in real-time feed

- **Team templates and presets**
  - `/team create <domain> --devs N --qa N --designer --researcher`
  - `/agent add <name> --preset senior_dev|qa|pm|pr_reviewer|...`
  - 11 presets: pm, senior_dev, junior_dev, qa, designer, researcher, devops, writer, market_analyst, competitor_analyst, pr_reviewer

### Bug Fixes
- **Session crash fix** — bulletproof event loop with try/rescue/catch
- **RalphLoop noproc** — safe_ralph_call uses spawn (no link) to avoid EXIT signals
- **Normal exits ignored** — `{:EXIT, :normal}` no longer kills the session
- **Status bar atom vs string** — task counts now work correctly
- **`/aa` approve all** — fixed pattern matching bug with `-all` vs `--all`
- **Tasks without company** — now always created with company field
- **Agent output events** — tool_use visible, text_delta silenced

### Infrastructure
- **Nix flake** — `nix develop` for reproducible dev environment (Elixir 1.18)
- **setup.sh** — auto-detects Nix, highlighted PATH warning box
- **`shz` alias** — avoids macOS ShazamKit conflict
- **`shazam update`** — auto-update command (fetch + rebuild + install)
- **`shazam` no args** — opens interactive shell directly
- **Rust TUI required** — blocks if shazam-tui not built
- **PostHog analytics** — on shazam.dev landing page
- **GitHub Actions CI** — test workflow on push/PR
- **MIT License** — from first commit

## v0.1.0 (2026-03-17)

### Initial Release
- Elixir/OTP core: TaskBoard, RalphLoop, SessionPool, Metrics, EventBus
- Rust TUI with ratatui: scrollbar, mouse scroll, overlays
- Interactive shell with 30+ commands and ghost text autocomplete
- Hierarchical agent teams (PM -> Dev -> QA)
- Human-in-the-loop approval workflow
- Session pooling for token efficiency
- Module locking and peer reassignment
- shazam.yaml configuration
- REST API + WebSocket on port 4040

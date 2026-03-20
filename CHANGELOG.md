# Changelog

## v0.8.0 (2026-03-20)

### Features
- **Git-awareness** — agents see branch, status, recent commits, and modified files
  - Auto-injected into prompts for new sessions and stateless providers
  - Prevents duplicate work and merge conflicts between agents
  - Pure `System.cmd("git", ...)` — zero dependencies

- **Agent-to-agent communication** — agents can query each other's knowledge
  - Output `AGENT_QUERY: senior_2 What is the users table schema?` in any task
  - System reads target's learnings and topic files, injects response inline
  - Max 2 queries per task (prevents loops)
  - Passive — does NOT execute the other agent, only reads stored context
  - Team Knowledge instruction auto-injected when other agents exist

- **Agent Pulse (sparkline)** — real-time activity heartbeat per agent
  - Sparkline characters (▁▂▃▄▅▆▇█) based on events/second
  - Stall detection: ⚠ warning when no events for >30 seconds
  - Sent to TUI via status JSON for status bar display
  - Clears automatically when task completes

- **Project auto-detection** (`shazam init`)
  - Scans project files: package.json, mix.exs, Cargo.toml, go.mod, etc.
  - Detects: framework, language, database, styling, testing, package manager, CI/CD
  - Auto-suggests domains based on directory structure
  - Auto-suggests agents based on detected stack
  - New "Detected" template option (recommended) in the init wizard
  - Pre-fills tech_stack in shazam.yaml

### Bug Fixes
- **`shazam update` crash** — `git fetch --tags` failed on force-pushed tags. Fixed with `--force` flag.

## v0.7.0 (2026-03-20)

### Features
- **Context Manager** — cross-provider context persistence
  - Agents accumulate context automatically as they complete tasks
  - Works with ALL providers (Claude, Codex, Cursor, Gemini) — just text in the prompt
  - Atomized storage: context split into small topic files per agent, not one giant file
  - Auto-routing: entries go to the matching topic file by keyword overlap, or create new
  - Auto-trim: topic files kept under 100 lines, team activity under 200 entries
  - Agent index (`index.md`) auto-generated with links to all topics
  - Configurable: `context_history`, `team_activity`, `context_budget` in shazam.yaml

- **TF-IDF Search (ContextRAG)** — pure Elixir retrieval, zero external dependencies
  - Indexes all `.md` files in `context/`, `tasks/`, `memories/` recursively
  - TF-IDF scoring with stopword removal, augmented TF, partial match bonus
  - Returns top-K most relevant chunks within a token budget
  - Replaces keyword grep with ranked retrieval (~80-85% quality)

- **Auto-extracted Learnings** — agents learn from their own output
  - Regex patterns detect decisions, discoveries, tech stack, warnings
  - File-path analysis detects frameworks (Vue, React, Supabase, etc.)
  - Deduplication via Jaccard similarity (>0.7 = already known)
  - Stored in `_learnings.md` per agent, injected as "What You Know" in prompts
  - Consolidation: no repeated learnings across tasks

### Storage Structure
```
.shazam/context/
  agents/
    senior_1/
      index.md              # auto-generated links + key learnings
      _learnings.md         # decisions, discoveries, patterns (deduped)
      implement_jwt_auth.md # topic: auth work
      build_rest_api.md     # topic: API endpoints
    pm/
      index.md
      _learnings.md
      plan_auth_system.md
  team_activity.md          # chronological log (auto-trimmed)
```

## v0.6.1 (2026-03-20)

### Changes
- **Renamed binary to `shazam-cli`** — avoids conflict with macOS `/usr/bin/shazam` (ShazamKit)
  - `shazam-cli` is the real binary
  - `shazam` and `shz` are symlink aliases pointing to `shazam-cli`
  - `~/bin/shazam` now always resolves to Shazam CLI, not Apple ShazamKit
- **`shazam init`** now prompts for AI CLI provider (Claude, Codex, Cursor, Gemini)
  - Auto-detects installed CLIs and shows status
  - Generated YAML includes `provider:` field
- **`setup.sh`** updated to install as `shazam-cli` with aliases
- **`setup.sh`** now checks out latest git tag (stable releases)

## v0.6.0 (2026-03-20)

### Features
- **Multi-provider support** — use different AI CLIs per agent
  - `Shazam.Provider` behaviour with 6 callbacks: `start_session`, `stop_session`, `execute`, `supports_sessions?`, `name`, `available?`
  - **4 providers built-in:** Claude Code, Codex, Cursor, Gemini
  - `provider:` field in shazam.yaml — set globally or per-agent
  - Session-based providers (Claude) use SessionPool; stateless providers (Codex, Cursor, Gemini) create ephemeral executions
  - `Shazam.Provider.Resolver` maps names to modules
  - Fully backward-compatible — Claude Code remains the default

### Configuration Example
```yaml
provider: claude_code           # default for all agents

agents:
  pm:
    role: Project Manager
    provider: claude_code       # uses Claude (fast for PM)
  senior_1:
    role: Senior Developer
    provider: codex             # uses Codex CLI
  senior_2:
    role: Senior Developer
    provider: cursor            # uses Cursor CLI
```

## v0.5.1 (2026-03-20)

### Features
- **Plugin event filtering** — `events:` field in shazam.yaml restricts when a plugin is called
  - Omit `events:` to run on all implemented callbacks (default)
  - Example: `events: [after_task_complete, before_query]`
  - `/plugins` command now shows which events each plugin listens to
  - Available events: `on_init`, `before_task_create`, `after_task_create`, `before_task_complete`, `after_task_complete`, `before_query`, `after_query`, `on_tool_use`

## v0.5.0 (2026-03-20)

### Features
- **Plugin System** — extensible middleware architecture for the agent lifecycle
  - Plugins are Elixir modules in `.shazam/plugins/*.ex`, compiled at runtime
  - `use Shazam.Plugin` behaviour with optional callbacks
  - **Events:** `on_init`, `before_task_create`, `after_task_create`, `before_task_complete`, `after_task_complete`, `before_query`, `after_query`, `on_tool_use`
  - "before" hooks can mutate input or halt the pipeline; "after" hooks can mutate output
  - Context: agents list, tasks list, company name, per-plugin config
  - Zero-cost when no plugins loaded (persistent_term fast path, no GenServer call)
  - Pipeline execution: data flows through plugins in alphabetical filename order
  - `/plugins` — list loaded plugins
  - `/plugins reload` — hot-reload plugins from disk
  - `plugins:` section in shazam.yaml for per-plugin configuration
  - Example plugins: logger, webhook, auto-context injection

## v0.4.2 (2026-03-20)

### Refactoring
- **`cli/repl.ex`** — removed ~1400 lines of dead ANSI fallback code (1525 -> 99 lines)
- **`cli/tui_port/commands.ex`** — split monolithic 1466-line file into 5 focused modules:
  - `Commands.System` — /start, /stop, /resume, /help, /config, etc.
  - `Commands.Tasks` — /task, /approve, /reject, /kill-task, etc.
  - `Commands.Agents` — /agent add, /team create, /org, etc.
  - `Commands.Review` — /review with all sub-flags
  - `Commands.Tools` — /plan, /qa, /memory-bank
- **`task_board.ex`** — extracted persistence logic into `TaskBoard.Persistence`
- **`company.ex`** — extracted builder/config into `Company.Builder`
- **`ralph_loop.ex`** — removed temporary debug logging, restored clean Logger calls
- Zero compile warnings (was ~60)
- Largest file reduced from 1525 to ~545 lines

## v0.4.1 (2026-03-19)

### Bug Fixes
- **Critical: Tasks not executing since v0.3.0** — `resolve_agent_profile` used `a[:name]` on `AgentWorker` structs which don't implement the `Access` behaviour, causing `UndefinedFunctionError`. Every agent appeared as "not found", skipping all tasks silently.
- **RalphLoop race condition** — Company's async `:attach_ralph_loop` could recreate RalphLoop after `/start` resume, reverting to paused state. Fixed by changing default to `paused: false` and removing company auto-restore from Application boot.
- **Clean shutdown** — `Application.stop(:shazam)` called before `System.halt(0)` for proper OTP cleanup.

### Diagnostics
- Detailed RalphLoop logging to `/tmp/shazam-ralph.log` — pending counts, candidate details, agent resolution, checkout results.

## v0.4.0 (2026-03-19)

### Features
- **QA System** — automated QA checklists with test cases
  - `/qa` — list QA docs and status
  - `/qa --generate <id>` — generate QA doc for a completed task
  - `/qa --validate <id>` — assign QA agent to run validation
  - `/qa --report` — generate daily QA report
  - `/qa --auto on|off` — auto-generate QA docs on task completion
  - `qa_auto: true` in shazam.yaml config
  - QA docs saved in `.shazam/qa/` with test case tables and checkboxes
  - QA agent marks [x] for passing tests, creates bug reports for failures
  - README index auto-updated with progress tracking

- **Plan System** — phased execution planning
  - `/plan <description>` — PM creates a phased plan
  - `/plan --list` — list all plans
  - `/plan --show <id>` — show plan with phases and tasks
  - `/plan --approve <id>` — create all tasks with dependencies (auto-approved)
  - Plans saved in `.shazam/plans/` as .md files
  - Auto-parse PM output on completion

- **Memory Bank** — project knowledge management
  - `/memory-bank` — list memory bank files
  - `/memory-bank --update` — PM analyzes codebase and creates skill memories

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

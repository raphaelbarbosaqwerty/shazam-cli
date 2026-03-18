# Shazam — AI Agent Architecture

```
                          ┌─────────────┐
                          │   YOU (CEO)  │
                          │  Human-in-   │
                          │  the-Loop    │
                          └──────┬───────┘
                                 │
                          Creates tasks &
                          approves outputs
                                 │
                ┌────────────────┼────────────────┐
                │                │                │
         ┌──────▼──────┐  ┌─────▼──────┐  ┌──────▼──────┐
         │  PM Dev Team │  │ PM Analysts │  │  PM Design  │
         │  (Haiku 4.5) │  │ (Haiku 4.5) │  │ (Haiku 4.5) │
         └──────┬───────┘  └─────┬───────┘  └─────────────┘
                │                │
     ┌──────┬──┴──┐        ┌────┴─────┐
     │      │     │        │          │
  ┌──▼──┐┌──▼─┐┌──▼──┐ ┌──▼───┐  ┌───▼────┐
  │ Dev ││ Dev ││ QA  │ │Market│  │Compet. │
  │ Sr. ││ Jr. ││     │ │Analyst│ │Analyst │
  └─────┘└────┘└─────┘ └──────┘  └────────┘
  Opus/   Sonnet  Sonnet  Sonnet    Sonnet
  Sonnet
```

## How It Works

```
You create a task
    └──► PM breaks it into subtasks (no code, just delegation)
            ├──► Dev implements features & fixes
            ├──► QA writes tests & reports bugs
            ├──► Analyst researches market/competitors
            └──► Results flow back up to PM
                    └──► PM creates follow-up tasks if needed
```

## Core Loop

```
┌─────────────────────────────────────────────┐
│                 RalphLoop                   │
│                                             │
│  Poll ──► Pick task ──► Checkout session    │
│                              │              │
│                        Execute on           │
│                        Claude Code          │
│                              │              │
│                        Parse output ──►     │
│                        Create subtasks      │
│                              │              │
│                        Checkin session       │
│                        (reuse next time)     │
└─────────────────────────────────────────────┘
```

## Key Concepts

- **Session Pool** — Sessions persist between tasks (saves tokens, preserves context)
- **Human-in-the-Loop** — PM subtasks go to approval queue before execution
- **Memory Banks** — Each agent has persistent memory across tasks
- **Cross-team Delegation** — PMs can route tasks to other teams
- **Role Separation** — Devs implement, QA tests, Analysts research, PMs delegate
- **Auto-retry** — Failed tasks retry with exponential backoff
- **Parallel Execution** — Up to N agents work simultaneously

## Agent Rules

| Role | Can Do | Cannot Do |
|------|--------|-----------|
| PM | Delegate, break down tasks | Read code, use tools |
| Dev | Implement, fix bugs | Write tests |
| QA | Write tests, report bugs | Implement features |
| Analyst | Research, analyze URLs | Write code |

## Tech Stack

- **Backend** — Elixir/OTP (GenServer, ETS, SQLite)
- **AI Engine** — Claude Code SDK (persistent sessions)
- **Frontend** — Flutter (real-time via WebSocket)
- **Models** — Haiku for PMs, Sonnet/Opus for workers

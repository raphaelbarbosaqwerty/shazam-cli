defmodule Mix.Tasks.Shazam.Dashboard do
  @moduledoc "Interactive terminal dashboard for Shazam."
  @shortdoc "Live TUI dashboard with agent status and events"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @refresh_interval 2_000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string], aliases: [c: :company])

    Helpers.ensure_app()

    company = Helpers.find_company(opts)

    unless company do
      Formatter.error("No company running. Start with 'mix shazam.start'")
      System.halt(1)
    end

    # Subscribe to events for live log
    Shazam.API.EventBus.subscribe()

    # Initial state
    state = %{
      company: company,
      events: [],
      max_events: 12,
      tick: 0
    }

    # Run dashboard loop
    loop(state)
  end

  defp loop(state) do
    # Drain all pending events
    state = drain_events(state)

    # Render
    render(state)

    # Wait for next tick or event
    receive do
      {:event, event} when is_map(event) ->
        state = add_event(state, event)
        loop(state)
    after
      @refresh_interval ->
        loop(%{state | tick: state.tick + 1})
    end
  end

  defp drain_events(state) do
    receive do
      {:event, event} when is_map(event) ->
        drain_events(add_event(state, event))
    after
      0 -> state
    end
  end

  defp add_event(state, event) do
    events = [event | state.events] |> Enum.take(state.max_events)
    %{state | events: events}
  end

  defp render(state) do
    # Clear screen
    IO.write([IO.ANSI.clear(), IO.ANSI.home()])

    company = state.company

    # Header bar
    IO.puts([
      IO.ANSI.bright(), IO.ANSI.cyan(),
      " ┌─ Shazam Dashboard ─────────────────────────────────────────────────┐",
      IO.ANSI.reset()
    ])

    # Company info
    try do
      info = Shazam.company_info(company)
      mission = info["mission"] || info[:mission] || ""

      # Agent counts
      statuses = Shazam.statuses(company)
      agent_count = length(statuses)
      working = Enum.count(statuses, fn s -> (s["status"] || s[:status]) in ["working", "thinking"] end)
      idle = agent_count - working

      # Task counts
      tasks = Shazam.tasks(%{"company" => company})
      task_pending = Enum.count(tasks, & &1["status"] == "pending")
      task_running = Enum.count(tasks, & &1["status"] == "running")
      task_done = Enum.count(tasks, & &1["status"] == "completed")

      # Ralph status
      ralph_state = if Shazam.RalphLoop.exists?(company) do
        s = Shazam.RalphLoop.status(company)
        if s[:paused], do: "paused", else: "running"
      else
        "off"
      end

      # Summary line
      IO.puts([
        IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
        IO.ANSI.bright(), company, IO.ANSI.reset(),
        IO.ANSI.faint(), " — #{mission}", IO.ANSI.reset(),
        pad_to(70 - String.length(company) - String.length(mission)),
        IO.ANSI.cyan(), "│", IO.ANSI.reset()
      ])

      IO.puts([
        IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
        IO.ANSI.green(), "▲ #{agent_count} agents", IO.ANSI.reset(), "  ",
        IO.ANSI.yellow(), "● #{working} working", IO.ANSI.reset(), "  ",
        IO.ANSI.faint(), "○ #{idle} idle", IO.ANSI.reset(), "  │  ",
        IO.ANSI.blue(), "⏳ #{task_pending + task_running} tasks", IO.ANSI.reset(), "  ",
        IO.ANSI.green(), "✓ #{task_done} done", IO.ANSI.reset(), "  ",
        "Loop: ", ralph_status_colored(ralph_state),
        pad_to(2),
        IO.ANSI.cyan(), "│", IO.ANSI.reset()
      ])

      IO.puts([
        IO.ANSI.cyan(),
        " ├──────────────────────────────────────────────────────────────────────┤",
        IO.ANSI.reset()
      ])

      # Agent table
      IO.puts([
        IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
        IO.ANSI.bright(), "AGENTS", IO.ANSI.reset(),
        pad_to(63),
        IO.ANSI.cyan(), "│", IO.ANSI.reset()
      ])

      Enum.each(statuses, fn s ->
        name = s["name"] || s[:name] || "?"
        role = s["role"] || s[:role] || "?"
        status = s["status"] || s[:status] || "idle"
        domain = s["domain"] || s[:domain]
        budget = s["budget"] || s[:budget] || 100_000
        budget_used = s["budget_used"] || s[:budget_used] || 0

        status_icon = case status do
          "working" -> [IO.ANSI.green(), "●", IO.ANSI.reset()]
          "thinking" -> [IO.ANSI.blue(), "●", IO.ANSI.reset()]
          "idle" -> [IO.ANSI.faint(), "○", IO.ANSI.reset()]
          "error" -> [IO.ANSI.red(), "●", IO.ANSI.reset()]
          _ -> [IO.ANSI.faint(), "○", IO.ANSI.reset()]
        end

        domain_tag = if domain, do: [IO.ANSI.faint(), " [#{domain}]", IO.ANSI.reset()], else: []
        bar = Formatter.progress_bar(budget_used, budget)

        name_padded = String.pad_trailing(name, 16)
        role_padded = String.pad_trailing(role, 20)
        status_padded = String.pad_trailing(status, 10)

        IO.puts([
          IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
          "  ", status_icon, " ", name_padded, role_padded, status_padded, bar, domain_tag,
          IO.ANSI.cyan(), IO.ANSI.reset()
        ])
      end)

      # Tasks section
      running_tasks = Enum.filter(tasks, & &1["status"] in ["running", "pending"]) |> Enum.take(5)

      if running_tasks != [] do
        IO.puts([
          IO.ANSI.cyan(),
          " ├──────────────────────────────────────────────────────────────────────┤",
          IO.ANSI.reset()
        ])

        IO.puts([
          IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
          IO.ANSI.bright(), "TASKS", IO.ANSI.reset(),
          pad_to(64),
          IO.ANSI.cyan(), "│", IO.ANSI.reset()
        ])

        Enum.each(running_tasks, fn t ->
          title = String.slice(t["title"] || "", 0, 40)
          assigned = t["assigned_to"] || "—"
          status = t["status"] || "?"
          icon = if status == "running", do: [IO.ANSI.yellow(), "⏳"], else: [IO.ANSI.faint(), "📋"]

          IO.puts([
            IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
            "  ", icon, IO.ANSI.reset(), " ",
            String.pad_trailing(title, 42),
            IO.ANSI.faint(), "→ #{assigned}", IO.ANSI.reset()
          ])
        end)
      end

    rescue
      _ ->
        IO.puts([
          IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
          IO.ANSI.red(), "  Error fetching company data", IO.ANSI.reset(),
          pad_to(40),
          IO.ANSI.cyan(), "│", IO.ANSI.reset()
        ])
    end

    # Events section
    IO.puts([
      IO.ANSI.cyan(),
      " ├──────────────────────────────────────────────────────────────────────┤",
      IO.ANSI.reset()
    ])

    IO.puts([
      IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
      IO.ANSI.bright(), "LIVE OUTPUT", IO.ANSI.reset(),
      pad_to(58),
      IO.ANSI.cyan(), "│", IO.ANSI.reset()
    ])

    if state.events == [] do
      IO.puts([
        IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
        IO.ANSI.faint(), "  Waiting for events...", IO.ANSI.reset(),
        pad_to(46),
        IO.ANSI.cyan(), "│", IO.ANSI.reset()
      ])
    else
      state.events
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.each(fn event ->
        line = format_event_inline(event)
        IO.puts([
          IO.ANSI.cyan(), " │ ", IO.ANSI.reset(),
          "  ", line,
          IO.ANSI.cyan(), IO.ANSI.reset()
        ])
      end)
    end

    # Footer
    IO.puts([
      IO.ANSI.cyan(),
      " └──────────────────────────── q:quit  r:refresh ───────────────────────┘",
      IO.ANSI.reset()
    ])
  end

  defp format_event_inline(event) do
    type = event[:event] || event["event"] || "?"
    agent = event[:agent] || event["agent"] || ""
    title = event[:title] || event["title"] || event[:text] || event["text"] || ""
    title = String.slice(to_string(title), 0, 50)

    {icon, color} = case type do
      "task_created" -> {"📋", IO.ANSI.blue()}
      "task_started" -> {"🔧", IO.ANSI.yellow()}
      "task_completed" -> {"✅", IO.ANSI.green()}
      "task_failed" -> {"❌", IO.ANSI.red()}
      "agent_output" -> {"💬", IO.ANSI.cyan()}
      _ -> {"  ", IO.ANSI.faint()}
    end

    [
      IO.ANSI.faint(), time_str(), " ", IO.ANSI.reset(),
      color, String.pad_trailing(to_string(agent), 14), IO.ANSI.reset(),
      icon, " ", title
    ]
  end

  defp time_str do
    Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
  end

  defp ralph_status_colored("running"), do: [IO.ANSI.green(), "running", IO.ANSI.reset()]
  defp ralph_status_colored("paused"), do: [IO.ANSI.yellow(), "paused", IO.ANSI.reset()]
  defp ralph_status_colored(s), do: [IO.ANSI.faint(), s, IO.ANSI.reset()]

  defp pad_to(n) when n > 0, do: String.duplicate(" ", n)
  defp pad_to(_), do: ""
end

defmodule Shazam.CLI.Commands.Dashboard do
  @moduledoc """
  Implements `shazam dashboard` — a simple TUI that refreshes every 3 s
  showing agents, task counts, and active work.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string, port: :integer])
    port = opts[:port] || @port
    company = opts[:company] || Shared.yaml_company()

    unless company do
      Formatter.error("No company. Use --company NAME or shazam.yaml")
      System.halt(1)
    end

    dashboard_loop(port, company, [], 0)
  end

  # ── private ───────────────────────────────────────────────

  defp dashboard_loop(port, company, events, _tick) do
    IO.write([IO.ANSI.clear(), IO.ANSI.home()])

    # Header
    IO.puts([
      IO.ANSI.bright(),
      IO.ANSI.cyan(),
      " ┌─ Shazam Dashboard ─────────────────────────────────────────────┐",
      IO.ANSI.reset()
    ])

    # Fetch data
    agents =
      case HttpClient.get(port, "/api/companies/#{URI.encode(company)}/agents") do
        {:ok, %{"agents" => a}} when is_list(a) -> a
        _ -> []
      end

    tasks =
      case HttpClient.get(port, "/api/tasks?company=#{URI.encode(company)}") do
        {:ok, %{"tasks" => t}} when is_list(t) -> t
        _ -> []
      end

    working = Enum.count(agents, fn a -> a["status"] in ["working", "thinking"] end)
    idle = length(agents) - working
    pending = Enum.count(tasks, &(&1["status"] in ["pending", "running"]))
    done = Enum.count(tasks, &(&1["status"] == "completed"))

    IO.puts([
      IO.ANSI.cyan(),
      " │ ",
      IO.ANSI.reset(),
      IO.ANSI.bright(),
      company,
      IO.ANSI.reset(),
      String.duplicate(" ", max(1, 66 - String.length(company))),
      IO.ANSI.cyan(),
      "│",
      IO.ANSI.reset()
    ])

    IO.puts([
      IO.ANSI.cyan(),
      " │ ",
      IO.ANSI.reset(),
      IO.ANSI.green(),
      "▲ #{length(agents)} agents",
      IO.ANSI.reset(),
      "  ",
      IO.ANSI.yellow(),
      "● #{working} working",
      IO.ANSI.reset(),
      "  ",
      IO.ANSI.faint(),
      "○ #{idle} idle",
      IO.ANSI.reset(),
      "  │  ",
      IO.ANSI.blue(),
      "⏳ #{pending} tasks",
      IO.ANSI.reset(),
      "  ",
      IO.ANSI.green(),
      "✓ #{done} done",
      IO.ANSI.reset(),
      String.duplicate(" ", max(1, 10)),
      IO.ANSI.cyan(),
      "│",
      IO.ANSI.reset()
    ])

    IO.puts([
      IO.ANSI.cyan(),
      " ├─────────────────────────────────────────────────────────────────────┤",
      IO.ANSI.reset()
    ])

    # Agents
    IO.puts([
      IO.ANSI.cyan(),
      " │ ",
      IO.ANSI.reset(),
      IO.ANSI.bright(),
      " AGENTS",
      IO.ANSI.reset(),
      String.duplicate(" ", 60),
      IO.ANSI.cyan(),
      "│",
      IO.ANSI.reset()
    ])

    Enum.each(agents, fn a ->
      name = String.pad_trailing(a["name"] || "?", 16)
      role = String.pad_trailing(a["role"] || "?", 22)
      status = a["status"] || "idle"

      icon =
        case status do
          "working" -> [IO.ANSI.green(), "●"]
          "thinking" -> [IO.ANSI.blue(), "●"]
          _ -> [IO.ANSI.faint(), "○"]
        end

      domain = if a["domain"], do: [IO.ANSI.faint(), " [#{a["domain"]}]"], else: []

      IO.puts([
        IO.ANSI.cyan(),
        " │ ",
        IO.ANSI.reset(),
        "  ",
        icon,
        IO.ANSI.reset(),
        " ",
        name,
        role,
        String.pad_trailing(status, 10),
        domain,
        IO.ANSI.reset()
      ])
    end)

    # Running tasks
    active_tasks = Enum.filter(tasks, &(&1["status"] in ["running", "pending"])) |> Enum.take(5)

    if active_tasks != [] do
      IO.puts([
        IO.ANSI.cyan(),
        " ├─────────────────────────────────────────────────────────────────────┤",
        IO.ANSI.reset()
      ])

      IO.puts([
        IO.ANSI.cyan(),
        " │ ",
        IO.ANSI.reset(),
        IO.ANSI.bright(),
        " TASKS",
        IO.ANSI.reset(),
        String.duplicate(" ", 61),
        IO.ANSI.cyan(),
        "│",
        IO.ANSI.reset()
      ])

      Enum.each(active_tasks, fn t ->
        title = String.slice(t["title"] || "", 0, 40) |> String.pad_trailing(42)
        assigned = t["assigned_to"] || "—"

        icon =
          if t["status"] == "running",
            do: [IO.ANSI.yellow(), "⏳"],
            else: [IO.ANSI.faint(), "📋"]

        IO.puts([
          IO.ANSI.cyan(),
          " │ ",
          IO.ANSI.reset(),
          "  ",
          icon,
          IO.ANSI.reset(),
          " ",
          title,
          IO.ANSI.faint(),
          "→ #{assigned}",
          IO.ANSI.reset()
        ])
      end)
    end

    # Footer
    IO.puts([
      IO.ANSI.cyan(),
      " └─────────────────────────── Ctrl+C to quit ── refreshes every 3s ──┘",
      IO.ANSI.reset()
    ])

    Process.sleep(3000)
    dashboard_loop(port, company, events, 0)
  end
end

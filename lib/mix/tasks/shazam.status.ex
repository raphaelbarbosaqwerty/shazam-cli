defmodule Mix.Tasks.Shazam.Status do
  @moduledoc "Show status of running Shazam companies and agents."
  @shortdoc "Display current system status"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string], aliases: [c: :company])

    Helpers.ensure_app()

    companies = Helpers.running_companies()

    if companies == [] do
      Formatter.warning("No companies running")
      Formatter.dim("Run 'mix shazam.start' to boot from shazam.yaml")
      return_or_halt()
    end

    target = if opts[:company], do: [opts[:company]], else: companies

    Enum.each(target, fn name ->
      print_company(name)
    end)
  end

  defp print_company(name) do
    Formatter.header("#{name}")

    try do
      info = Shazam.company_info(name)
      Formatter.info("Mission: #{info["mission"] || info[:mission] || "—"}")

      # Agent statuses
      statuses = Shazam.statuses(name)

      if is_list(statuses) and statuses != [] do
        headers = ["Agent", "Role", "Status", "Domain", "Budget"]
        rows = Enum.map(statuses, fn s ->
          [
            s["name"] || s[:name] || "?",
            s["role"] || s[:role] || "?",
            s["status"] || s[:status] || "idle",
            s["domain"] || s[:domain] || "—",
            format_budget(s["budget_used"] || 0, s["budget"] || 100_000)
          ]
        end)
        Formatter.table(headers, rows)
      else
        Formatter.dim("No agent status data")
      end

      # RalphLoop
      if Shazam.RalphLoop.exists?(name) do
        ralph = Shazam.RalphLoop.status(name)
        loop_status = if ralph[:paused], do: "paused", else: "running"
        Formatter.info("RalphLoop: #{loop_status}")

        running = ralph[:running_tasks] || []
        if running != [] do
          Formatter.info("Running tasks: #{length(running)}")
          Enum.each(running, fn t ->
            IO.puts(["    ", IO.ANSI.yellow(), "⏳ ", IO.ANSI.reset(), to_string(t)])
          end)
        end
      end

      # Tasks summary
      tasks = Shazam.tasks(%{"company" => name})
      if is_list(tasks) and tasks != [] do
        by_status = Enum.group_by(tasks, & &1["status"])
        counts = ["pending", "running", "completed", "failed"]
          |> Enum.map(fn s -> "#{s}: #{length(by_status[s] || [])}" end)
          |> Enum.join("  ")
        Formatter.info("Tasks: #{counts}")
      end

      # Metrics
      try do
        metrics = Shazam.Metrics.get_all()
        if is_map(metrics) && map_size(metrics) > 0 do
          total_tokens = metrics |> Map.values() |> Enum.map(& &1[:total_tokens] || 0) |> Enum.sum()
          Formatter.info("Total tokens used: #{format_number(total_tokens)}")
        end
      rescue
        _ -> :ok
      end
    rescue
      e ->
        Formatter.error("Failed to get info for '#{name}': #{inspect(e)}")
    end

    IO.puts("")
  end

  defp format_budget(used, total) do
    pct = if total > 0, do: round(used / total * 100), else: 0
    "#{format_number(used)}/#{format_number(total)} (#{pct}%)"
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_number(n), do: to_string(n)

  defp return_or_halt, do: :ok
end

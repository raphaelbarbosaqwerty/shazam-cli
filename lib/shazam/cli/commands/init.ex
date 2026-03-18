defmodule Shazam.CLI.Commands.Init do
  @moduledoc """
  Implements `shazam init` — interactive project scaffold that creates
  a `shazam.yaml` config in the current directory.
  """

  alias Shazam.CLI.Formatter

  def run(_args) do
    Formatter.banner_static()

    config_dir = ".shazam"
    config_file = Path.join(config_dir, "shazam.yaml")

    if File.exists?(config_file) do
      IO.write("  #{config_file} already exists. Overwrite? [y/N]: ")

      case IO.read(:stdio, :line) |> to_string() |> String.trim() |> String.downcase() do
        "y" -> :ok
        _ ->
          Formatter.info("Aborted.")
          System.halt(0)
      end
    end

    name = prompt("Company name", Path.basename(File.cwd!()))
    mission = prompt("Mission", "Build great software")

    IO.puts("")
    Formatter.info("Choose a team template:")
    IO.puts("")
    IO.puts("  1) Developer Team  — PM + 2 senior devs")
    IO.puts("  2) Content Team    — Editor + Writer + Researcher")
    IO.puts("  3) QA Team         — PM + 2 QA engineers")
    IO.puts("  4) Solo Agent      — One powerful agent")
    IO.puts("")

    choice = prompt("Template", "1")

    agents =
      case choice do
        "1" -> dev_team_agents()
        "2" -> content_team_agents()
        "3" -> qa_team_agents()
        "4" -> solo_agent()
        _ -> dev_team_agents()
      end

    domains = detect_domains()

    config = %{name: name, mission: mission, agents: agents, domains: domains}
    yaml = Shazam.CLI.YamlParser.to_yaml(config)
    File.mkdir_p!(config_dir)
    File.write!(config_file, yaml)

    IO.puts("")
    Formatter.success("Created #{config_file}")
    Formatter.info("#{length(agents)} agent(s) configured")
    IO.puts("")
    Formatter.dim("Next: shazam start")
    IO.puts("")
  end

  # ── private ───────────────────────────────────────────────

  defp prompt(label, default) do
    IO.write("  #{label} [#{default}]: ")
    answer = IO.read(:stdio, :line) |> to_string() |> String.trim()
    if answer == "", do: default, else: answer
  end

  defp detect_domains do
    cwd = File.cwd!()

    [{"lib", "Backend code"}, {"src", "Source"}, {"app", "App"}, {"frontend", "Frontend"}, {"test", "Tests"}]
    |> Enum.filter(fn {dir, _} -> File.dir?(Path.join(cwd, dir)) end)
    |> Enum.reduce(%{}, fn {dir, desc}, acc ->
      Map.put(acc, dir, %{"description" => desc, "paths" => ["#{dir}/"]})
    end)
  end

  defp dev_team_agents do
    [
      %{name: "pm", role: "Project Manager", supervisor: nil, budget: 200_000,
        model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "Glob", "WebSearch"]},
      %{name: "senior_1", role: "Senior Developer", supervisor: "pm", budget: 150_000,
        tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]},
      %{name: "senior_2", role: "Senior Developer", supervisor: "pm", budget: 150_000,
        tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]}
    ]
  end

  defp content_team_agents do
    [
      %{name: "pm", role: "Project Manager", supervisor: nil, budget: 150_000,
        model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "WebSearch", "WebFetch"]},
      %{name: "senior_writer", role: "Senior Content Writer", supervisor: "pm", budget: 100_000,
        tools: ["Read", "Edit", "Write", "WebSearch"]},
      %{name: "senior_researcher", role: "Senior Researcher", supervisor: "pm", budget: 100_000,
        tools: ["Read", "WebSearch", "WebFetch", "Grep"]}
    ]
  end

  defp qa_team_agents do
    [
      %{name: "pm", role: "Project Manager", supervisor: nil, budget: 200_000,
        model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "Glob", "WebSearch"]},
      %{name: "qa_senior_1", role: "Senior QA Engineer", supervisor: "pm", budget: 150_000,
        tools: ["Read", "Bash", "Grep", "Glob", "Edit", "Write"]},
      %{name: "qa_senior_2", role: "Senior QA Engineer", supervisor: "pm", budget: 150_000,
        tools: ["Read", "Bash", "Grep", "Glob", "Edit", "Write"]}
    ]
  end

  defp solo_agent do
    [%{name: "agent", role: "Senior Full-Stack Developer", supervisor: nil, budget: 200_000,
       tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "WebSearch"]}]
  end
end

defmodule Mix.Tasks.Shazam.Init do
  @moduledoc "Initialize a Shazam project in the current directory."
  @shortdoc "Create shazam.yaml with interactive wizard"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers, YamlParser}

  @presets %{
    "dev" => %{
      label: "Developer Team",
      agents: [
        %{name: "pm", role: "Project Manager", supervisor: nil, budget: 200_000,
          model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "Glob", "WebSearch"]},
        %{name: "senior_1", role: "Senior Developer", supervisor: "pm", budget: 150_000,
          tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]},
        %{name: "senior_2", role: "Senior Developer", supervisor: "pm", budget: 150_000,
          tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]}
      ]
    },
    "content" => %{
      label: "Content Team",
      agents: [
        %{name: "pm", role: "Project Manager", supervisor: nil, budget: 150_000,
          model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "WebSearch", "WebFetch"]},
        %{name: "senior_writer", role: "Senior Content Writer", supervisor: "pm", budget: 100_000,
          tools: ["Read", "Edit", "Write", "WebSearch"]},
        %{name: "senior_researcher", role: "Senior Researcher", supervisor: "pm", budget: 100_000,
          tools: ["Read", "WebSearch", "WebFetch", "Grep"]}
      ]
    },
    "qa" => %{
      label: "QA Team",
      agents: [
        %{name: "pm", role: "Project Manager", supervisor: nil, budget: 200_000,
          model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "Glob", "WebSearch"]},
        %{name: "qa_senior_1", role: "Senior QA Engineer", supervisor: "pm", budget: 150_000,
          tools: ["Read", "Bash", "Grep", "Glob", "Edit", "Write"]},
        %{name: "qa_senior_2", role: "Senior QA Engineer", supervisor: "pm", budget: 150_000,
          tools: ["Read", "Bash", "Grep", "Glob", "Edit", "Write"]}
      ]
    },
    "solo" => %{
      label: "Solo Agent",
      agents: [
        %{name: "agent", role: "Senior Full-Stack Developer", supervisor: nil, budget: 200_000,
          tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "WebSearch"]}
      ]
    }
  }

  @impl Mix.Task
  def run(_args) do
    Formatter.banner()

    config_dir = ".shazam"
    config_file = Path.join(config_dir, "shazam.yaml")

    if File.exists?(config_file) do
      unless Helpers.confirm?("#{config_file} already exists. Overwrite?", false) do
        Formatter.info("Aborted.")
        System.halt(0)
      end
    end

    name = Helpers.prompt("Company name", Path.basename(File.cwd!()))
    mission = Helpers.prompt("Mission", "Build great software")

    # Detect available CLI providers
    IO.puts("")
    Formatter.info("Choose your AI CLI provider:")
    IO.puts("")
    providers = detect_providers()
    Enum.each(Enum.with_index(providers, 1), fn {{key, label, available}, i} ->
      status = if available, do: "\e[32m(installed)\e[0m", else: "\e[31m(not found)\e[0m"
      IO.puts("  #{i}) #{label} #{status}")
      _ = key
    end)
    IO.puts("")

    provider_choice = Helpers.prompt("Provider", "1")
    provider_idx = String.to_integer(provider_choice) - 1
    {provider_key, _, _} = Enum.at(providers, provider_idx, {"claude_code", "Claude Code", true})

    IO.puts("")
    Formatter.info("Choose a team template:")
    IO.puts("")
    IO.puts("  1) Developer Team  — PM + 2 senior devs")
    IO.puts("  2) Content Team    — PM + Senior Writer + Senior Researcher")
    IO.puts("  3) QA Team         — PM + 2 senior QAs")
    IO.puts("  4) Solo Agent      — One powerful senior agent")
    IO.puts("  5) Custom          — Build from scratch")
    IO.puts("")

    choice = Helpers.prompt("Template", "1")

    {agents, domains} = case choice do
      "1" -> {@presets["dev"].agents, detect_domains()}
      "2" -> {@presets["content"].agents, %{}}
      "3" -> {@presets["qa"].agents, detect_domains()}
      "4" -> {@presets["solo"].agents, detect_domains()}
      "5" -> {build_custom_agents(), detect_domains()}
      _ -> {@presets["dev"].agents, detect_domains()}
    end

    config = %{
      name: name,
      mission: mission,
      agents: agents,
      domains: domains,
      provider: provider_key
    }

    yaml = YamlParser.to_yaml(config)
    File.mkdir_p!(config_dir)
    File.write!(config_file, yaml)

    IO.puts("")
    Formatter.success("Created #{config_file}")
    Formatter.info("#{length(agents)} agent(s) configured")
    IO.puts("")
    Formatter.dim("Next: mix shazam.start")
    IO.puts("")
  end

  defp build_custom_agents do
    count = Helpers.prompt("How many agents?", "2") |> String.to_integer()

    Enum.map(1..count, fn i ->
      IO.puts("")
      Formatter.info("Agent #{i}:")
      name = Helpers.prompt("  Name", "agent_#{i}")
      role = Helpers.prompt("  Role", "Developer")
      supervisor = Helpers.prompt("  Supervisor (leave blank for none)", "")
      supervisor = if supervisor == "", do: nil, else: supervisor

      %{
        name: name,
        role: role,
        supervisor: supervisor,
        budget: 100_000,
        tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]
      }
    end)
  end

  defp detect_providers do
    [
      {"claude_code", "Claude Code (claude)", System.find_executable("claude") != nil},
      {"codex", "OpenAI Codex (codex)", System.find_executable("codex") != nil},
      {"cursor", "Cursor (cursor)", System.find_executable("cursor") != nil},
      {"gemini", "Google Gemini (gemini)", System.find_executable("gemini") != nil}
    ]
  end

  defp detect_domains do
    cwd = File.cwd!()
    candidates = [
      {"lib", "Backend / library code"},
      {"src", "Source code"},
      {"app", "Application code"},
      {"frontend", "Frontend code"},
      {"test", "Tests"},
      {"priv", "Private resources"}
    ]

    candidates
    |> Enum.filter(fn {dir, _} -> File.dir?(Path.join(cwd, dir)) end)
    |> Enum.reduce(%{}, fn {dir, desc}, acc ->
      Map.put(acc, dir, %{"description" => desc, "paths" => ["#{dir}/"]})
    end)
  end
end

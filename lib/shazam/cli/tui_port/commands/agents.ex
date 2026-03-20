defmodule Shazam.CLI.TuiPort.Commands.Agents do
  @moduledoc """
  Agent management commands: /agents, /agents --init, /agent presets, /agent add,
  /agent edit, /agent remove, /team create, /team templates, /org
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/agent presets", state) do
    presets = Shazam.AgentPresets.list()
    lines = presets |> Enum.map(fn p -> "  #{p.id} — #{p.label} (#{p.category})" end)
    Helpers.send_event(state.port, "system", "info", "Available presets:")
    Enum.each(lines, fn line ->
      Helpers.send_event(state.port, "system", "info", line)
    end)
    state
  end

  def handle_command("/agent add " <> args, state) do
    parts = String.split(String.trim(args), " ", parts: 2)
    name = List.first(parts) || ""
    rest = Enum.at(parts, 1, "")

    if name == "" do
      Helpers.send_event(state.port, "system", "error",
        "Usage: /agent add <name> [--preset senior_dev|qa|pm|...] [--domain D] [--supervisor S] [--budget N]")
    else
      opts = parse_agent_flags(rest)

      new_agent = if opts["preset"] do
        build_agent_from_preset(name, opts, state)
      else
        role = opts["role"] || "Senior Developer"
        domain = opts["domain"]
        supervisor = opts["supervisor"] || Helpers.find_pm_name(state)
        budget = String.to_integer(opts["budget"] || "150000")
        %{
          name: name, role: role, domain: domain, supervisor: supervisor,
          budget: budget, heartbeat_interval: 60_000, model: nil,
          fallback_model: nil, tools: default_agent_tools(role), skills: [],
          modules: if(domain, do: [%{"name" => domain, "paths" => []}], else: []),
          system_prompt: nil
        }
      end

      # Update the running company with all agents (including the new one)
      if Code.ensure_loaded?(Shazam.Company) do
        try do
          all_agents = ((Helpers.deep_get(state, [:company, :agents]) || []) ++ [new_agent])
          Shazam.Company.update_agents(state.company.name, all_agents)
        catch
          _, _ -> :ok
        end
      end

      # Create agent .md config file
      if opts["preset"] do
        Shazam.AgentConfig.write_preset(name, opts["preset"])
      else
        Shazam.AgentConfig.write_agent(name, new_agent)
      end

      # Update state
      agents = (Helpers.deep_get(state, [:company, :agents]) || []) ++ [new_agent]
      state = put_in(state, [:company, :agents], agents)

      # Persist to YAML
      persist_agents_to_yaml(state)

      Helpers.send_event(state.port, "system", "agent_added", "Agent '#{name}' added (#{new_agent.role})")
      Status.send_status(state)
      state
    end
  end

  def handle_command("/agent edit " <> args, state) do
    parts = String.split(String.trim(args), " ", parts: 2)
    name = List.first(parts) || ""
    rest = Enum.at(parts, 1, "")

    agents = Helpers.deep_get(state, [:company, :agents]) || []
    agent_idx = Enum.find_index(agents, fn a -> a[:name] == name end)

    if agent_idx == nil do
      Helpers.send_event(state.port, "system", "error", "Agent '#{name}' not found")
      state
    else
      opts = parse_agent_flags(rest)
      agent = Enum.at(agents, agent_idx)

      updated = agent
        |> then(fn a -> if opts["role"], do: Map.put(a, :role, opts["role"]), else: a end)
        |> then(fn a -> if opts["domain"], do: Map.put(a, :domain, opts["domain"]), else: a end)
        |> then(fn a -> if opts["supervisor"], do: Map.put(a, :supervisor, opts["supervisor"]), else: a end)
        |> then(fn a -> if opts["budget"], do: Map.put(a, :budget, String.to_integer(opts["budget"])), else: a end)
        |> then(fn a -> if opts["model"], do: Map.put(a, :model, opts["model"]), else: a end)

      agents = List.replace_at(agents, agent_idx, updated)
      state = put_in(state, [:company, :agents], agents)

      persist_agents_to_yaml(state)

      changes = opts |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(", ")
      Helpers.send_event(state.port, "system", "agent_updated", "Agent '#{name}' updated: #{changes}")
      state
    end
  end

  def handle_command("/agent remove " <> name, state) do
    name = String.trim(name)
    agents = Helpers.deep_get(state, [:company, :agents]) || []
    new_agents = Enum.reject(agents, fn a -> a[:name] == name end)

    if length(new_agents) == length(agents) do
      Helpers.send_event(state.port, "system", "error", "Agent '#{name}' not found")
      state
    else
      state = put_in(state, [:company, :agents], new_agents)
      persist_agents_to_yaml(state)
      Helpers.send_event(state.port, "system", "agent_removed", "Agent '#{name}' removed")
      Status.send_status(state)
      state
    end
  end

  def handle_command("/org", state) do
    if Code.ensure_loaded?(Shazam.Company) do
      agents = Shazam.Company.get_agents(state.company.name)
      tree_text = Helpers.format_org_tree(agents)
      Helpers.send_event(state.port, "system", "org_tree", tree_text)
    end
    state
  end

  def handle_command("/agents --init", state) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    if agents == [] do
      Helpers.send_event(state.port, "system", "error", "No agents configured")
    else
      existing = Shazam.AgentConfig.list_agents()

      created = Enum.reduce(agents, 0, fn agent, count ->
        name = agent[:name] || agent.name
        if name in existing do
          count
        else
          Shazam.AgentConfig.write_agent(name, %{
            role: agent[:role] || "Agent",
            model: agent[:model],
            budget: agent[:budget] || 100_000,
            tools: agent[:tools] || [],
            system_prompt: agent[:system_prompt]
          })
          count + 1
        end
      end)

      skipped = length(agents) - created
      Helpers.send_event(state.port, "system", "info",
        "Agent configs: #{created} created, #{skipped} already exist in .shazam/agents/")

      if created > 0 do
        Helpers.send_event(state.port, "system", "info",
          "Edit the .md files in .shazam/agents/ to customize agent prompts and behavior")
      end
    end
    state
  end

  def handle_command("/agents", state) do
    agents_data = Status.build_dashboard_data(state)
    Helpers.send_json(state.port, %{type: "agent_list", agents: agents_data |> Enum.map(fn a ->
      Map.merge(a, %{model: find_agent_model(state, a.name)})
    end)})
    state
  end

  # ── Team Templates ────────────────────────────────────────

  def handle_command("/team create " <> args, state) do
    parts = String.split(String.trim(args), " ", parts: 2)
    domain = List.first(parts) || ""
    rest = Enum.at(parts, 1, "")

    if domain == "" do
      Helpers.send_event(state.port, "system", "error",
        "Usage: /team create <domain> [--devs N] [--qa N] [--pm] [--researcher] [--designer]")
      state
    else
      opts = parse_agent_flags(rest)
      devs = String.to_integer(opts["devs"] || "2")
      qa_count = String.to_integer(opts["qa"] || "0")
      _has_pm = opts["pm"] != nil or true  # always include a PM
      has_researcher = opts["researcher"] != nil
      has_designer = opts["designer"] != nil

      pm_name = Helpers.find_pm_name(state)
      _created = []

      # Create dev agents
      new_agents = for i <- 1..devs do
        build_agent_from_preset("#{domain}_dev_#{i}", %{
          "preset" => "senior_dev", "domain" => domain,
          "supervisor" => pm_name
        }, state)
      end

      # Create QA agents
      qa_agents = for i <- 1..qa_count do
        build_agent_from_preset("#{domain}_qa_#{i}", %{
          "preset" => "qa", "domain" => domain,
          "supervisor" => pm_name
        }, state)
      end

      # Optional agents
      extra = []
      extra = if has_researcher do
        extra ++ [build_agent_from_preset("#{domain}_researcher", %{
          "preset" => "researcher", "domain" => domain,
          "supervisor" => pm_name
        }, state)]
      else
        extra
      end
      extra = if has_designer do
        extra ++ [build_agent_from_preset("#{domain}_designer", %{
          "preset" => "designer", "domain" => domain,
          "supervisor" => pm_name
        }, state)]
      else
        extra
      end

      all_new = new_agents ++ qa_agents ++ extra
      agents = (Helpers.deep_get(state, [:company, :agents]) || []) ++ all_new
      state = put_in(state, [:company, :agents], agents)
      persist_agents_to_yaml(state)

      names = all_new |> Enum.map(& &1.name) |> Enum.join(", ")
      Helpers.send_event(state.port, "system", "team_created",
        "Team '#{domain}' created: #{length(all_new)} agents (#{names})")
      Status.send_status(state)
      state
    end
  end

  def handle_command("/team templates", state) do
    lines = [
      "Team templates create multiple agents for a domain:",
      "",
      "  /team create <domain> --devs 2 --qa 1",
      "  /team create backend --devs 3 --qa 1 --researcher",
      "  /team create frontend --devs 2 --designer",
      "",
      "Flags:",
      "  --devs N        Number of Senior Developers (default: 2)",
      "  --qa N          Number of QA Engineers (default: 0)",
      "  --researcher    Add a Researcher agent",
      "  --designer      Add a Designer agent"
    ]
    Enum.each(lines, fn line ->
      Helpers.send_event(state.port, "system", "info", line)
    end)
    state
  end

  # ── Private helpers ──────────────────────────────────────

  defp default_agent_tools(role) do
    r = String.downcase(role)
    cond do
      String.contains?(r, "manager") or String.contains?(r, "pm") ->
        ["Read", "Grep", "Glob", "WebSearch"]
      String.contains?(r, "developer") or String.contains?(r, "dev") ->
        ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]
      String.contains?(r, "qa") or String.contains?(r, "test") ->
        ["Read", "Bash", "Grep", "Glob"]
      true ->
        ["Read", "Grep", "Glob"]
    end
  end

  defp parse_agent_flags(str) do
    Regex.scan(~r/--(\w+)\s+([^\-]+?)(?=\s+--|$)/, str)
    |> Enum.reduce(%{}, fn [_, key, value], acc ->
      Map.put(acc, key, String.trim(value))
    end)
  end

  defp build_agent_from_preset(name, opts, state) do
    preset_id = opts["preset"]
    case Shazam.AgentPresets.get(preset_id) do
      nil ->
        # Fallback to basic agent
        role = opts["role"] || "Senior Developer"
        %{
          name: name, role: role, domain: opts["domain"],
          supervisor: opts["supervisor"] || Helpers.find_pm_name(state),
          budget: String.to_integer(opts["budget"] || "150000"),
          heartbeat_interval: 60_000, model: nil, fallback_model: nil,
          tools: default_agent_tools(role), skills: [],
          modules: [], system_prompt: nil
        }
      preset ->
        d = preset.defaults
        domain = opts["domain"]
        %{
          name: name,
          role: opts["role"] || d.role,
          domain: domain,
          supervisor: opts["supervisor"] || Helpers.find_pm_name(state),
          budget: String.to_integer(opts["budget"] || to_string(d.budget)),
          heartbeat_interval: 60_000,
          model: d.model,
          fallback_model: nil,
          tools: d.tools,
          skills: [],
          modules: if(domain, do: [%{"name" => domain, "paths" => []}], else: []),
          system_prompt: d.system_prompt
        }
    end
  end

  defp persist_agents_to_yaml(state) do
    try do
      config = Helpers.deep_get(state, [:company, :config]) || %{}
      agents = Helpers.deep_get(state, [:company, :agents]) || []
      updated_config = Map.put(config, :agents, agents)

      yaml_path = if File.exists?(".shazam/shazam.yaml"), do: ".shazam/shazam.yaml", else: "shazam.yaml"
      yaml = Shazam.CLI.YamlParser.to_yaml(updated_config)
      File.write!(yaml_path, yaml)
    rescue
      _ -> :ok
    end
  end

  defp find_agent_model(state, name) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []
    case Enum.find(agents, fn a -> a[:name] == name end) do
      nil -> nil
      a -> a[:model]
    end
  end
end

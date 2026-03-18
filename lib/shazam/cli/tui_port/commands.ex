defmodule Shazam.CLI.TuiPort.Commands do
  @moduledoc """
  All `/command` handling clauses extracted from TuiPort.
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/quit", state) do
    Helpers.send_json(state.port, %{type: "quit"})
    Process.sleep(100)
    Helpers.cleanup(state)
    state
  end

  def handle_command("/exit", state), do: handle_command("/quit", state)

  def handle_command("/help", state) do
    commands = [
      "/start              — Start agents",
      "/stop               — Stop agents (keep REPL open)",
      "/pause              — Pause RalphLoop",
      "/resume             — Resume RalphLoop",
      "/dashboard          — Agent progress dashboard",
      "/status             — Company and agent overview",
      "/agents             — List all agents with status",
      "/org                — Show org chart",
      "/tasks              — List tasks [--clear]",
      "/task <title>       — Create a new task [--to agent]",
      "/approve [id]       — Approve pending task (--all for batch)",
      "/aa                 — Approve all pending tasks (shortcut)",
      "/reject <id>        — Reject a pending task",
      "/msg <ag> <msg>     — Send message to agent",
      "/auto-approve       — Toggle auto-approve [on|off]",
      "/config             — Show current configuration",
      "",
      "Agent Management:",
      "/agent add <name>   — Add new agent (--preset, --role, --domain, --budget)",
      "/agent edit <name>  — Edit agent (--role, --domain, --budget, --model)",
      "/agent remove <name>— Remove agent",
      "/agent presets      — List available agent presets",
      "",
      "Team Templates:",
      "/team create <domain> — Create team (--devs N, --qa N, --designer, --researcher)",
      "/team templates     — Show team template help",
      "",
      "Task Actions:",
      "/pause-task <id>    — Pause a task",
      "/resume-task <id>   — Resume a paused task",
      "/kill-task <id>     — Kill running task",
      "/retry-task <id>    — Retry failed task",
      "/delete-task <id>   — Delete a task",
      "",
      "/clear              — Clear scroll region",
      "/help               — Show this help",
      "/exit               — Exit Shazam"
    ]
    Enum.each(commands, fn cmd ->
      Helpers.send_event(state.port, "system", "help", cmd)
    end)
    state
  end

  def handle_command("/start", state) do
    config = state.company.config
    company_name = state.company.name

    unless Shazam.RalphLoop.exists?(company_name) do
      company_config = %{
        name: company_name,
        mission: config.mission,
        agents: config.agents,
        domain_config: config[:domain_config] || %{}
      }

      case Shazam.start_company(company_config) do
        {:ok, _} ->
          Helpers.send_event(state.port, "system", "company_started",
            "Company '#{company_name}' started — #{length(config.agents)} agent(s)")
        {:error, {:already_started, _}} ->
          Helpers.send_event(state.port, "system", "info", "Company '#{company_name}' already running")
        {:error, reason} ->
          Helpers.send_event(state.port, "system", "error", "Failed to start: #{inspect(reason)}")
      end
    end

    # Apply ralph_config
    if config[:ralph_config] do
      rc = config.ralph_config
      try do
        if rc[:auto_approve], do: Shazam.RalphLoop.set_auto_approve(company_name, true)
        Shazam.RalphLoop.set_config(company_name, "max_concurrent", rc[:max_concurrent] || 4)
      rescue
        _ -> :ok
      end
    end

    # Resume
    case Shazam.RalphLoop.resume(company_name) do
      {:ok, _} ->
        Helpers.send_event(state.port, "system", "ralph_resumed", "Agents are working")
      _ -> :ok
    end

    # Subscribe to EventBus now that company is running
    if Code.ensure_loaded?(Shazam.API.EventBus) do
      Shazam.API.EventBus.subscribe()
    end

    Status.send_status(state)
    state
  end

  def handle_command("/stop", state) do
    company_name = state.company.name
    if Code.ensure_loaded?(Shazam.RalphLoop) do
      Shazam.RalphLoop.pause(company_name)
      Helpers.send_event(state.port, "system", "ralph_paused", "Agents stopped")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/pause", state), do: handle_command("/stop", state)

  def handle_command("/resume", state) do
    company_name = state.company.name
    if Code.ensure_loaded?(Shazam.RalphLoop) do
      case Shazam.RalphLoop.resume(company_name) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "ralph_resumed", "Agents resumed")
        _ -> Helpers.send_event(state.port, "system", "info", "Could not resume")
      end
    end
    Status.send_status(state)
    state
  end

  def handle_command("/dashboard", state) do
    agents = Status.build_dashboard_data(state)
    Helpers.send_json(state.port, %{type: "dashboard", agents: agents})
    state
  end

  def handle_command("/status", state) do
    Status.send_status(state)
    state
  end

  def handle_command("/tasks" <> rest, state) do
    args = String.trim(rest)
    if args == "--clear" do
      if Code.ensure_loaded?(Shazam.TaskBoard) do
        Shazam.TaskBoard.clear_all()
      end
      Helpers.send_event(state.port, "system", "tasks_cleared", "All tasks cleared")
      Status.send_status(state)
    else
      tasks = Helpers.list_tasks(state)
      task_items = Enum.map(tasks, fn t ->
        %{
          id: t.id,
          title: t.title || "",
          status: to_string(t.status),
          assigned_to: t.assigned_to,
          created_by: t.created_by,
          created_at: format_task_time(t)
        }
      end)
      Helpers.send_json(state.port, %{type: "task_list", tasks: task_items})
    end
    state
  end

  defp format_task_time(task) do
    cond do
      is_struct(task[:created_at], DateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      is_struct(task[:created_at], NaiveDateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      is_binary(task[:created_at]) ->
        task.created_at
      Map.has_key?(task, :created_at) and is_struct(task.created_at, DateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      Map.has_key?(task, :created_at) and is_struct(task.created_at, NaiveDateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      true ->
        ""
    end
  end

  def handle_command("/task " <> title, state) do
    title = Helpers.expand_attachments(title, state)
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: title,
        created_by: "human",
        assigned_to: pm_name,
        priority: "normal",
        company: company_name
      })
      Helpers.send_event(state.port, pm_name, "task_created", title)
    end
    Status.send_status(state)
    state
  end

  def handle_command("/approve" <> rest, state) do
    args = String.trim(rest)
    cond do
      args in ["--all", "-all"] ->
        Helpers.approve_all(state)
        Helpers.send_json(state.port, %{type: "clear_approvals"})
      args != "" ->
        Helpers.approve_task(args, state)
      true ->
        Helpers.approve_next(state)
    end
    Status.send_status(state)
    state
  end

  def handle_command("/reject " <> task_id, state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.reject(String.trim(task_id))
    end
    Status.send_status(state)
    state
  end

  def handle_command("/config", state) do
    company_name = Helpers.deep_get(state, [:company, :name]) || "Shazam"
    mission = Helpers.deep_get(state, [:company, :config, :mission]) ||
              Helpers.deep_get(state, [:company, :mission]) || ""

    # Get runtime config from RalphLoop if available
    ralph_entries = if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      try do
        case Shazam.RalphLoop.status(company_name) do
          %{config: cfg} ->
            cfg
            |> Enum.map(fn {k, v} -> %{key: to_string(k), value: to_string(v)} end)
            |> Enum.sort_by(& &1.key)
          _ -> []
        end
      catch
        _, _ -> []
      end
    else
      []
    end

    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    static_entries = [
      %{key: "agents", value: "#{length(agents)}"},
      %{key: "workspace", value: Application.get_env(:shazam, :workspace, "-")},
    ]

    Helpers.send_json(state.port, %{
      type: "config_info",
      company: company_name,
      mission: mission,
      entries: static_entries ++ ralph_entries
    })
    state
  end

  # ── Agent Management ────────────────────────────────────────

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

      # Add to running company if available
      if Code.ensure_loaded?(Shazam.Company) do
        try do
          Shazam.Company.add_agent(state.company.name, new_agent)
        catch
          _, _ -> :ok
        end
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

  def handle_command("/org", state) do
    if Code.ensure_loaded?(Shazam.Company) do
      agents = Shazam.Company.get_agents(state.company.name)
      tree_text = Helpers.format_org_tree(agents)
      Helpers.send_event(state.port, "system", "org_tree", tree_text)
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

  defp find_agent_model(state, name) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []
    case Enum.find(agents, fn a -> a[:name] == name end) do
      nil -> nil
      a -> a[:model]
    end
  end

  def handle_command("/approve-all", state) do
    Helpers.approve_all(state)
    Helpers.send_json(state.port, %{type: "clear_approvals"})
    Status.send_status(state)
    state
  end

  def handle_command("/aa", state) do
    Helpers.approve_all(state)
    Helpers.send_json(state.port, %{type: "clear_approvals"})
    Status.send_status(state)
    state
  end

  def handle_command("/msg " <> rest, state) do
    case String.split(rest, " ", parts: 2) do
      [agent, message] ->
        if Code.ensure_loaded?(Shazam.AgentInbox) do
          Shazam.AgentInbox.push(String.trim(agent), %{
            from: "human",
            content: String.trim(message)
          })
          Helpers.send_event(state.port, agent, "message_sent", "Message sent to #{agent}")
        end
      _ ->
        Helpers.send_event(state.port, "system", "error", "Usage: /msg <agent> <message>")
    end
    state
  end

  def handle_command("/auto-approve" <> rest, state) do
    company_name = state.company[:name] || state.company.name
    arg = String.trim(rest)
    cond do
      arg in ["on", "true", "yes"] ->
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          Shazam.RalphLoop.set_auto_approve(company_name, true)
          Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: ON")
        end
      arg in ["off", "false", "no"] ->
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          Shazam.RalphLoop.set_auto_approve(company_name, false)
          Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: OFF")
        end
      true ->
        # Toggle
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          case Shazam.RalphLoop.status(company_name) do
            %{auto_approve: current} ->
              new_val = !current
              Shazam.RalphLoop.set_auto_approve(company_name, new_val)
              Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: #{if new_val, do: "ON", else: "OFF"}")
            _ ->
              Helpers.send_event(state.port, "system", "info", "Start agents first with /start")
          end
        end
    end
    state
  catch
    :exit, _ -> state
    _, _ -> state
  end

  def handle_command("/pause-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.pause_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_paused", "Task paused: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot pause: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.pause(task_id)
      Helpers.send_event(state.port, "system", "task_paused", "Task paused: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/resume-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.resume_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_resumed", "Task resumed: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot resume: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.resume_task(task_id)
      Helpers.send_event(state.port, "system", "task_resumed", "Task resumed: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/kill-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.kill_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_killed", "Task killed: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot kill: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.fail(task_id, "Killed by user")
      Helpers.send_event(state.port, "system", "task_killed", "Task killed: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/retry-task " <> task_id, state) do
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      case Shazam.TaskBoard.retry(task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_resumed", "Task retrying: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot retry: #{inspect(reason)}")
      end
    end
    Status.send_status(state)
    state
  end

  def handle_command("/delete-task " <> task_id, state) do
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.delete(task_id)
      Helpers.send_event(state.port, "system", "task_deleted", "Task deleted: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/start-task " <> task_id, state) do
    # Just ensure it's pending so RalphLoop picks it up
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      case Shazam.TaskBoard.get(task_id) do
        {:ok, task} ->
          if task.status in [:paused, :failed, :rejected] do
            Shazam.TaskBoard.retry(task_id)
          end
          Helpers.send_event(state.port, "system", "info", "Task queued: #{task_id}")
        _ ->
          Helpers.send_event(state.port, "system", "error", "Task not found: #{task_id}")
      end
    end
    Status.send_status(state)
    state
  end

  def handle_command("/clear", state) do
    Helpers.send_json(state.port, %{type: "clear"})
    state
  end

  def handle_command("/" <> cmd, state) do
    Helpers.send_event(state.port, "system", "error", "Unknown command: /#{cmd}. Type /help for available commands.")
    state
  end

  # Natural language → task for PM
  def handle_command(text, state) when text != "" do
    title = Helpers.expand_attachments(text, state)
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: title,
        created_by: "human",
        assigned_to: pm_name,
        priority: "normal",
        company: company_name
      })
      Helpers.send_event(state.port, pm_name, "task_created", title)
    end
    Status.send_status(state)
    state
  end

  def handle_command(_, state), do: state
end

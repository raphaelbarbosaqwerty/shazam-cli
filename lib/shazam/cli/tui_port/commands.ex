defmodule Shazam.CLI.TuiPort.Commands do
  @moduledoc """
  All `/command` handling clauses extracted from TuiPort.
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/quit", state) do
    Helpers.send_json(state.port, %{type: "quit"})
    Process.sleep(200)
    Helpers.shutdown(state)
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
      "/tasks              — List tasks [--clear|--sync|--export]",
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
      "/agents --init      — Generate .md config files for existing agents",
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
      "/search <query>     — Search tasks by title",
      "/export [filename]  — Export tasks to markdown",
      "/workspaces         — List configured workspaces (multi-repo)",
      "/memory             — Show memory usage breakdown",
      "/clear              — Clear scroll region",
      "/help               — Show this help",
      "",
      "PR Review:",
      "/review <pr>        — Review a pull request (number or URL)",
      "/review --post <id> — Post completed review to GitHub with inline comments",
      "/review --check <pr>— Verify if previous review comments were addressed",
      "/review --resolve <pr> — Resolve all conversation threads on a PR",
      "/review --learn     — Learn patterns from recent merged PR reviews",
      "/review --patterns  — Show learned review patterns",
      "",
      "Memory Bank:",
      "/memory-bank        — Show project memory bank files",
      "/memory-bank --update — Update memory bank by analyzing codebase",
      "",
      "/exit               — Exit Shazam",
      "",
      "Tips:",
      "  @path/to/file       — Reference files in tasks (auto-expanded)",
      "  Paste image path    — Attach images to tasks (.shazam/attachments/)"
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
          # Sync agents from YAML to Company GenServer (in case new agents were added)
          try do
            Shazam.Company.update_agents(company_name, config.agents)
          catch
            _, _ -> :ok
          end
          Helpers.send_event(state.port, "system", "info", "Company '#{company_name}' already running (agents synced)")
        {:error, reason} ->
          Helpers.send_event(state.port, "system", "error", "Failed to start: #{inspect(reason)}")
      end
    end

    # Wait for RalphLoop to register
    wait_for_ralph(company_name, 10)

    # Apply ralph_config
    if config[:ralph_config] && Shazam.RalphLoop.exists?(company_name) do
      rc = config.ralph_config
      safe_ralph_call(company_name, fn ->
        if rc[:auto_approve], do: Shazam.RalphLoop.set_auto_approve(company_name, true)
        Shazam.RalphLoop.set_config(company_name, "max_concurrent", rc[:max_concurrent] || 4)
      end)
    end

    # Resume
    if Shazam.RalphLoop.exists?(company_name) do
      safe_ralph_call(company_name, fn ->
        case Shazam.RalphLoop.resume(company_name) do
          {:ok, _} ->
            Helpers.send_event(state.port, "system", "ralph_resumed", "Agents are working")
          _ -> :ok
        end
      end)
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
    cond do
      args == "--sync" ->
        # Import tasks from .shazam/tasks/ files
        imported = Shazam.TaskFiles.read_all()
        new_count = Enum.count(imported, fn t ->
          case Shazam.TaskBoard.get(t.id) do
            {:ok, _} -> false
            _ -> true
          end
        end)
        Shazam.TaskFiles.sync_from_files()
        Helpers.send_event(state.port, "system", "info", "Synced #{length(imported)} tasks from .shazam/tasks/ (#{new_count} new)")
        Status.send_status(state)

      args == "--export" ->
        tasks = Helpers.list_tasks(state)
        Shazam.TaskFiles.sync_to_files(tasks)
        Helpers.send_event(state.port, "system", "info", "Exported #{length(tasks)} tasks to .shazam/tasks/")

      args == "--clear" ->
        company_name = Helpers.deep_get(state, [:company, :name])
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          tasks = Helpers.list_tasks(state)
          # Move completed/failed tasks to ETS only (files stay in .shazam/tasks/)
          # Only clear from runtime view, not from disk
          Enum.each(tasks, fn t ->
            if t.status in [:pending, :in_progress, :awaiting_approval] do
              Shazam.TaskBoard.delete(t.id)
            end
          end)
        end
        Helpers.send_event(state.port, "system", "tasks_cleared", "Active tasks cleared (completed tasks preserved)")
        Status.send_status(state)

      true ->
        tasks = Helpers.list_tasks(state)
        task_items = Enum.map(tasks, fn t ->
          %{
            id: t.id,
            title: t.title || "",
            status: to_string(t.status),
            assigned_to: t.assigned_to,
            created_by: t.created_by,
            created_at: format_task_time(t),
            result: if(is_binary(t.result), do: String.slice(t.result, 0..500), else: nil)
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

  def handle_command("/agents --init", state) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    if agents == [] do
      Helpers.send_event(state.port, "system", "error", "No agents configured")
    else
      existing = Shazam.AgentConfig.list_agents()
      new_count = 0

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

  def handle_command("/search " <> query, state) do
    query = String.trim(query)
    tasks = Helpers.list_tasks(state)
    matches = Enum.filter(tasks, fn t ->
      String.contains?(String.downcase(t.title || ""), String.downcase(query))
    end)
    task_items = Enum.map(matches, fn t ->
      %{
        id: t.id,
        title: t.title || "",
        status: to_string(t.status),
        assigned_to: t.assigned_to,
        created_by: t.created_by,
        created_at: format_task_time(t),
        result: if(is_binary(t.result), do: String.slice(t.result, 0..500), else: nil)
      }
    end)
    Helpers.send_json(state.port, %{type: "task_list", tasks: task_items})
    state
  end

  def handle_command("/export" <> rest, state) do
    filename = case String.trim(rest) do
      "" -> "shazam-export-#{Date.to_string(Date.utc_today())}.md"
      name -> name
    end
    tasks = Helpers.list_tasks(state)
    content = Enum.map_join(tasks, "\n\n---\n\n", fn t ->
      status = to_string(t.status)
      agent = t.assigned_to || "unassigned"
      result = if is_binary(t.result), do: "\n\n#{t.result}", else: ""
      "## #{t.title}\n\n**Status:** #{status} | **Agent:** #{agent} | **ID:** #{t.id}#{result}"
    end)
    header = "# Shazam Export — #{Date.to_string(Date.utc_today())}\n\n"
    File.write!(filename, header <> content)
    Helpers.send_event(state.port, "system", "info", "Exported #{length(tasks)} tasks to #{filename}")
    state
  end

  def handle_command("/clear", state) do
    Helpers.send_json(state.port, %{type: "clear"})
    state
  end

  def handle_command("/review " <> rest, state) do
    args = String.trim(rest)
    company_name = Helpers.deep_get(state, [:company, :name])

    try do
      cond do
        args == "--learn" ->
          Helpers.send_event(state.port, "system", "info", "Learning from recent PR reviews...")
          case Shazam.PRReviewer.learn() do
            {:ok, count} ->
              Helpers.send_event(state.port, "system", "info", "Learned #{count} patterns from merged PRs")
            {:error, reason} ->
              Helpers.send_event(state.port, "system", "error", "Failed to learn: #{inspect(reason)}")
          end

        args == "--patterns" ->
          patterns = Shazam.PRReviewer.patterns()
          if patterns == "" do
            Helpers.send_event(state.port, "system", "info", "No review patterns learned yet. Run /review --learn")
          else
            lines = String.split(patterns, "\n") |> Enum.take(20)
            Enum.each(lines, fn line ->
              Helpers.send_event(state.port, "system", "info", line)
            end)
          end

        String.starts_with?(args, "--post ") ->
          task_id = String.trim_leading(args, "--post ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Posting review to GitHub...")

          try do
            if Code.ensure_loaded?(Shazam.TaskBoard) do
              case Shazam.TaskBoard.get(task_id) do
                {:ok, task} when not is_nil(task.result) ->
                  # Extract PR number from title "Review PR #42"
                  pr_number = case Regex.run(~r/PR #(\d+)/, task.title) do
                    [_, num] -> num
                    _ -> nil
                  end

                  if pr_number do
                    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
                    case Shazam.PRReviewer.post_review(pr_number, task.result, workspace) do
                      {:ok, %{verdict: verdict, comments: count}} ->
                        Helpers.send_event(state.port, "reviewer", "info", "Review posted: #{verdict} with #{count} inline comments")
                      {:error, reason} ->
                        Helpers.send_event(state.port, "system", "error", "Failed to post: #{inspect(reason)}")
                    end
                  else
                    Helpers.send_event(state.port, "system", "error", "Could not extract PR number from task title")
                  end
                {:ok, _} ->
                  Helpers.send_event(state.port, "system", "error", "Task has no result yet. Wait for the reviewer to complete.")
                _ ->
                  Helpers.send_event(state.port, "system", "error", "Task #{task_id} not found")
              end
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Post review error: #{inspect(kind)}: #{inspect(reason)}")
          end

        String.starts_with?(args, "--check ") ->
          pr_number = String.trim_leading(args, "--check ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Checking if PR ##{pr_number} changes were addressed...")

          try do
            case Shazam.PRReviewer.check_review(pr_number) do
              {:ok, context} ->
                reviewer_profile = find_reviewer_agent(state)
                reviewer_name = reviewer_profile[:name] || Helpers.find_pm_name(state)

                prompt = """
                Check if the previous review comments have been addressed in the latest diff.

                Previous reviews:
                #{context.previous_reviews}

                Current diff:
                ```diff
                #{String.slice(context.current_diff, 0..8000)}
                ```

                For each previous comment, check if it was addressed. If all addressed, verdict APPROVE. If not, REQUEST_CHANGES with remaining issues.

                #{Shazam.PRReviewer.build_review_prompt(%{pr_number: pr_number, pr_info: "", diff: context.current_diff, files: [], file_contexts: [], patterns: ""}) |> String.split("IMPORTANT:") |> List.last()}
                """

                if Code.ensure_loaded?(Shazam.TaskBoard) do
                  Shazam.TaskBoard.create(%{
                    title: "Re-review PR ##{pr_number}",
                    assigned_to: reviewer_name,
                    created_by: "human",
                    company: Helpers.deep_get(state, [:company, :name]),
                    description: String.slice(prompt, 0..15_000)
                  })
                  Helpers.send_event(state.port, reviewer_name, "task_created", "Re-review task for PR ##{pr_number}")
                end
              {:error, reason} ->
                Helpers.send_event(state.port, "system", "error", "Check failed: #{inspect(reason)}")
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Check review error: #{inspect(kind)}: #{inspect(reason)}")
          end

        String.starts_with?(args, "--resolve ") ->
          pr_number = String.trim_leading(args, "--resolve ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Resolving threads on PR ##{pr_number}...")

          try do
            case Shazam.PRReviewer.resolve_threads(pr_number) do
              {:ok, count} ->
                Helpers.send_event(state.port, "reviewer", "info", "Resolved #{count} conversation threads")
              {:error, reason} ->
                Helpers.send_event(state.port, "system", "error", "Failed to resolve: #{inspect(reason)}")
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Resolve error: #{inspect(kind)}: #{inspect(reason)}")
          end

        true ->
          Helpers.send_event(state.port, "reviewer", "info", "Reviewing PR ##{args}...")

          case Shazam.PRReviewer.review(args) do
            {:ok, context} ->
              Helpers.send_event(state.port, "reviewer", "info", "Building review prompt (#{length(context.files)} files)...")
              prompt = Shazam.PRReviewer.build_review_prompt(context)
              # Truncate prompt to avoid oversized tasks
              prompt = String.slice(prompt, 0..15_000)
              reviewer_profile = find_reviewer_agent(state)
              reviewer_name = reviewer_profile[:name] || Helpers.find_pm_name(state)
              Helpers.send_event(state.port, "reviewer", "info", "Assigning to #{reviewer_name}...")

              if Code.ensure_loaded?(Shazam.TaskBoard) do
                Shazam.TaskBoard.create(%{
                  title: "Review PR ##{args}",
                  assigned_to: reviewer_name,
                  created_by: "human",
                  company: company_name,
                  description: prompt
                })
                Helpers.send_event(state.port, reviewer_name, "task_created", "PR ##{args} review task created")
              end

            {:error, reason} ->
              Helpers.send_event(state.port, "system", "error", "Review failed: #{inspect(reason)}")
          end
      end
    rescue
      e ->
        Helpers.send_event(state.port, "system", "error", "Review error: #{inspect(e)}")
    catch
      kind, reason ->
        Helpers.send_event(state.port, "system", "error", "Review error: #{inspect(kind)}: #{inspect(reason)}")
    end

    Status.send_status(state)
    state
  end

  defp find_reviewer_agent(state) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    case Enum.find(agents, fn a ->
      role = String.downcase(a[:role] || "")
      String.contains?(role, "review")
    end) do
      nil ->
        # Use PM as fallback if no reviewer exists
        pm_name = Helpers.find_pm_name(state)
        %{name: pm_name, role: "Project Manager"}
      agent ->
        agent
    end
  end

  # ── RalphLoop safety helpers ──────────────────────────────

  defp wait_for_ralph(company_name, 0), do: :ok
  defp wait_for_ralph(company_name, retries) do
    if Shazam.RalphLoop.exists?(company_name) do
      :ok
    else
      Process.sleep(200)
      wait_for_ralph(company_name, retries - 1)
    end
  end

  defp safe_ralph_call(_company_name, fun) do
    # Use spawn + monitor instead of Task.async to avoid EXIT signals killing the TUI
    ref = make_ref()
    parent = self()
    pid = spawn(fn ->
      try do
        result = fun.()
        send(parent, {ref, :ok, result})
      catch
        kind, reason ->
          send(parent, {ref, :error, {kind, reason}})
      end
    end)

    receive do
      {^ref, :ok, result} -> result
      {^ref, :error, _} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  def handle_command("/memory", state) do
    mem = :erlang.memory()
    total_mb = div(mem[:total], 1_048_576)
    processes_mb = div(mem[:processes], 1_048_576)
    ets_mb = div(mem[:ets], 1_048_576)
    atom_mb = div(mem[:atom], 1_048_576)
    binary_mb = div(mem[:binary], 1_048_576)
    system_mb = div(mem[:system], 1_048_576)

    process_count = :erlang.system_info(:process_count)

    # Token usage from metrics
    all_metrics = if Code.ensure_loaded?(Shazam.Metrics), do: Shazam.Metrics.get_all(), else: %{}
    total_tokens = all_metrics |> Map.values() |> Enum.reduce(0, fn m, acc -> acc + (m[:total_tokens] || 0) end)
    total_cost = all_metrics |> Map.values() |> Enum.reduce(0.0, fn m, acc -> acc + (m[:cost_usd] || 0.0) end)

    lines = [
      "Memory Usage:",
      "  Total:     #{total_mb} MB",
      "  Processes: #{processes_mb} MB (#{process_count} processes)",
      "  ETS:       #{ets_mb} MB",
      "  Binary:    #{binary_mb} MB",
      "  Atoms:     #{atom_mb} MB",
      "  System:    #{system_mb} MB",
      "",
      "Token Usage (cumulative):",
      "  Total tokens: #{total_tokens}",
      "  Total cost:   $#{Float.round(total_cost, 4)}"
    ]

    # Per-agent breakdown
    agent_lines = all_metrics
      |> Enum.map(fn {agent, m} ->
        tokens = m[:total_tokens] || 0
        cost = m[:cost_usd] || 0.0
        if tokens > 0, do: "  #{agent}: #{tokens} tokens ($#{Float.round(cost, 4)})", else: nil
      end)
      |> Enum.reject(&is_nil/1)

    lines = if agent_lines != [] do
      lines ++ [""] ++ agent_lines
    else
      lines
    end

    Enum.each(lines, fn line ->
      Helpers.send_event(state.port, "system", "info", line)
    end)
    state
  end

  def handle_command("/workspaces", state) do
    workspaces = Application.get_env(:shazam, :workspaces, %{})
    if workspaces == %{} do
      Helpers.send_event(state.port, "system", "info", "No workspaces configured. Add a 'workspaces' section to shazam.yaml")
    else
      Enum.each(workspaces, fn {name, config} ->
        path = Map.get(config, :path) || Map.get(config, "path", "")
        exists = if File.dir?(path), do: "✓", else: "✗"
        Helpers.send_event(state.port, "system", "info", "  #{exists} #{name}: #{path}")
      end)
    end
    state
  end

  def handle_command("/memory-bank --update", state) do
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    Helpers.send_event(state.port, "system", "info", "Updating project memory bank...")

    # Create the memory bank directory structure
    memories_dir = Path.join(workspace, ".shazam/memories")
    File.mkdir_p!(Path.join(memories_dir, "project"))
    File.mkdir_p!(Path.join(memories_dir, "agents"))
    File.mkdir_p!(Path.join(memories_dir, "rules"))

    prompt = """
    Analyze this project's codebase thoroughly and create/update the memory bank files.

    You must READ the actual project files to understand the codebase. Use Read, Grep, and Glob tools.

    Create or update these files in .shazam/memories/:

    1. **project/overview.md** — Project name, purpose, tech stack, main features, directory structure
    2. **project/architecture.md** — Key architectural patterns, module organization, data flow
    3. **project/conventions.md** — Code style, naming conventions, import order, error handling patterns
    4. **rules/testing.md** — Testing framework, test patterns, what to test
    5. **rules/git-workflow.md** — Branch naming, commit message format, PR process
    6. **SKILL.md** — Root index linking to all memory files

    Each file must have YAML frontmatter:
    ```
    ---
    name: file-name
    description: One line description
    tags: tag1, tag2
    ---
    ```

    Be thorough — read package.json/mix.exs for dependencies, look at folder structure,
    read a few source files to understand patterns.
    """

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: "Update project memory bank",
        assigned_to: pm_name,
        created_by: "human",
        company: company_name,
        description: prompt
      })
      Helpers.send_event(state.port, pm_name, "task_created", "Memory bank update task created")
    end

    Status.send_status(state)
    state
  end

  def handle_command("/memory-bank", state) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    memories_dir = Path.join(workspace, ".shazam/memories")

    if File.dir?(memories_dir) do
      files = list_memory_files(memories_dir, "")
      if files == [] do
        Helpers.send_event(state.port, "system", "info", "Memory bank empty. Run /memory-bank --update")
      else
        Helpers.send_event(state.port, "system", "info", "Memory bank (.shazam/memories/):")
        Enum.each(files, fn file ->
          Helpers.send_event(state.port, "system", "info", "  #{file}")
        end)
      end
    else
      Helpers.send_event(state.port, "system", "info", "No memory bank found. Run /memory-bank --update")
    end
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

  defp list_memory_files(dir, prefix) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          display = if prefix == "", do: entry, else: "#{prefix}/#{entry}"
          if File.dir?(path) do
            list_memory_files(path, display)
          else
            [display]
          end
        end)
      _ -> []
    end
  end

  def handle_command(_, state), do: state
end

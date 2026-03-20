defmodule Shazam.CLI.TuiPort.Commands.System do
  @moduledoc """
  System commands: /quit, /exit, /help, /start, /stop, /pause, /resume,
  /dashboard, /status, /config, /clear, /memory, /workspaces
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
      "Planning:",
      "/plan <description>  — Create an execution plan (PM analyzes and generates)",
      "/plan --list         — List all plans",
      "/plan --show <id>    — Show plan details",
      "/plan --approve <id> — Approve plan and create all tasks",
      "",
      "QA:",
      "/qa                  — List QA checklists and status",
      "/qa --generate <id>  — Generate QA doc for a task",
      "/qa --validate <id>  — Assign QA agent to validate a task",
      "/qa --report         — Generate daily QA report",
      "/qa --auto on|off    — Toggle auto-generation on task completion",
      "",
      "Plugins:",
      "/plugins             — List loaded plugins",
      "/plugins reload      — Reload plugins from .shazam/plugins/",
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
    config = state.company[:config] || state.company.config
    company_name = state.company[:name] || state.company.name

    company_config = %{
      name: company_name,
      mission: config[:mission] || config.mission,
      agents: config[:agents] || config.agents,
      domain_config: config[:domain_config] || %{}
    }

    # Always try to start — handles all cases:
    # 1. Fresh start (no Company, no RalphLoop)
    # 2. Company exists but RalphLoop was killed (clear_previous_session)
    # 3. Everything already running

    # Step 1: Ensure Company exists
    case Shazam.start_company(company_config) do
      {:ok, _} ->
        Helpers.send_event(state.port, "system", "company_started",
          "Company '#{company_name}' started — #{length(company_config.agents)} agent(s)")
      {:error, {:already_started, _}} ->
        # Company exists — sync agents
        try do
          Shazam.Company.update_agents(company_name, company_config.agents)
        catch
          _, _ -> :ok
        end
        Helpers.send_event(state.port, "system", "info", "Company '#{company_name}' ready (#{length(company_config.agents)} agents)")
      {:error, reason} ->
        Helpers.send_event(state.port, "system", "error", "Failed to start company: #{inspect(reason)}")
    end

    # Step 2: Wait for RalphLoop to be ready (Company creates it automatically)
    wait_for_ralph(company_name, 15)

    # Step 3: Apply config
    if Shazam.RalphLoop.exists?(company_name) do
      try do
        rc = config[:ralph_config] || %{}
        if rc[:auto_approve], do: Shazam.RalphLoop.set_auto_approve(company_name, true)
        if rc[:max_concurrent], do: Shazam.RalphLoop.set_config(company_name, "max_concurrent", rc[:max_concurrent])
      catch
        _, _ -> :ok
      end
    end

    # Step 4: Resume (RalphLoop starts paused by default)
    try do
      Shazam.RalphLoop.resume(company_name)
      Helpers.send_event(state.port, "system", "ralph_resumed", "Agents are working")
    catch
      :exit, _ ->
        Helpers.send_event(state.port, "system", "info", "RalphLoop not ready. Try /start again.")
      _, _ -> :ok
    end

    # Subscribe to EventBus now that company is running
    if Code.ensure_loaded?(Shazam.API.EventBus) do
      Shazam.API.EventBus.subscribe()
    end

    # Step 5: Load plugins from .shazam/plugins/
    try do
      workspace = Application.get_env(:shazam, :workspace, File.cwd!())
      plugin_configs = config[:plugins] || []
      case Shazam.PluginManager.load_plugins(company_name, workspace, plugin_configs) do
        {:ok, 0} -> :ok
        {:ok, n} ->
          Helpers.send_event(state.port, "system", "info", "#{n} plugin(s) loaded")
          Shazam.PluginManager.run_pipeline(:on_init, nil, company_name: company_name)
        _ -> :ok
      end
    catch
      _, _ -> :ok
    end

    Status.send_status(state)
    state
  end

  def handle_command("/stop", state) do
    company_name = state.company[:name] || state.company.name
    try do
      Shazam.RalphLoop.pause(company_name)
      Helpers.send_event(state.port, "system", "ralph_paused", "Agents stopped")
    catch
      :exit, _ -> Helpers.send_event(state.port, "system", "info", "RalphLoop not running")
      _, _ -> :ok
    end
    Status.send_status(state)
    state
  end

  def handle_command("/pause", state), do: handle_command("/stop", state)

  def handle_command("/resume", state) do
    company_name = state.company[:name] || state.company.name
    try do
      result = Shazam.RalphLoop.resume(company_name)
      if result in [:ok, {:ok, :resumed}] do
        Helpers.send_event(state.port, "system", "ralph_resumed", "Agents resumed")
      else
        Helpers.send_event(state.port, "system", "info", "Resume returned: #{inspect(result)}")
      end
    catch
      :exit, _ -> Helpers.send_event(state.port, "system", "info", "RalphLoop not running. Try /start")
      _, _ -> :ok
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

  def handle_command("/clear", state) do
    Helpers.send_json(state.port, %{type: "clear"})
    state
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

  def handle_command("/plugins reload", state) do
    case Shazam.PluginManager.reload() do
      {:ok, n} ->
        Helpers.send_event(state.port, "system", "info", "Reloaded #{n} plugin(s)")
      _ ->
        Helpers.send_event(state.port, "system", "info", "No plugins to reload")
    end
    state
  end

  def handle_command("/plugins", state) do
    plugins = Shazam.PluginManager.list_plugins()
    if plugins == [] do
      Helpers.send_event(state.port, "system", "info", "No plugins loaded. Place .ex files in .shazam/plugins/")
    else
      Helpers.send_event(state.port, "system", "info", "#{length(plugins)} plugin(s) loaded:")
      Enum.each(plugins, fn {mod, config, events} ->
        events_str = case events do
          :all -> "all events"
          list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
        end
        config_str = if config == %{}, do: "", else: " | config: #{inspect(config)}"
        Helpers.send_event(state.port, "system", "info", "  #{inspect(mod)} [#{events_str}]#{config_str}")
      end)
      Helpers.send_event(state.port, "system", "info", "")
      Helpers.send_event(state.port, "system", "info", "Available events: on_init, before_task_create, after_task_create, before_task_complete, after_task_complete, before_query, after_query, on_tool_use")
    end
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

  # ── RalphLoop safety helpers ──────────────────────────────

  defp wait_for_ralph(_company_name, 0), do: :ok
  defp wait_for_ralph(company_name, retries) do
    if Shazam.RalphLoop.exists?(company_name) do
      :ok
    else
      Process.sleep(200)
      wait_for_ralph(company_name, retries - 1)
    end
  end

end

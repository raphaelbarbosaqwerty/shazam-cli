defmodule Shazam.CLI.TuiPort.Commands.System do
  @moduledoc """
  System commands: /quit, /exit, /help, /start, /stop, /resume,
  /restart, /dashboard, /status, /config, /clear, /memory, /workspaces,
  /github sync
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
      "/stop               — Pause agents (keep shell open)",
      "/resume             — Resume RalphLoop",
      "/dashboard          — Open agent dashboard with metrics and current tasks",
      "/status             — Refresh status bar",
      "/agents             — List all agents with status",
      "/org                — Show org chart",
      "/tasks              — List tasks [--clear|--sync|--export]",
      "/task <title>       — Create a new task [--to agent]",
      "/approve <id>       — Approve pending task",
      "/approve-all        — Approve all pending tasks",
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
      "/health             — Health check (agents, stalls, circuit breaker)",
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
      "Knowledge:",
      "/knowledge          — List knowledge/memory bank files",
      "/knowledge --update — Analyze codebase and update knowledge bank",
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
      "/plugins install <owner>/<repo>        — Install plugin from GitHub repo",
      "/plugins install <owner>/<repo> --path <file> — Install specific file from repo",
      "/plugins remove <name>                 — Remove a plugin",
      "",
      "/restart            — Restart Shazam (stop all agents + re-init)",
      "/github sync        — Re-import from GitHub Projects without restarting",
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

    # Set default provider
    if config[:provider] do
      Application.put_env(:shazam, :default_provider, config[:provider])
    end

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
        if rc[:qa_auto], do: Application.put_env(:shazam, :qa_auto, true)
        # Apply ContextManager config
        Shazam.ContextManager.configure(
          context_history: rc[:context_history] || 5,
          team_activity: rc[:team_activity] || 10,
          context_budget: rc[:context_budget] || 4_000
        )
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
          case Shazam.PluginManager.run_pipeline(:on_init, nil, company_name: company_name) do
            {:ok, _} -> :ok
            {:halt, reason} ->
              Helpers.send_event(state.port, "system", "error", "Plugin on_init halted: #{inspect(reason)}")
            _ -> :ok
          end
          # Show plugin log messages
          show_plugin_log(state)
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

  def handle_command("/plugins install " <> args, state) do
    {repo, opts} = parse_plugin_install_args(args)

    if repo == "" do
      Helpers.send_event(state.port, "system", "error", "Usage: /plugins install <owner>/<repo> [--path path/to/file.ex]")
      state
    else
      Helpers.send_event(state.port, "system", "info", "Installing plugin from #{repo}...")

      workspace = Application.get_env(:shazam, :workspace, File.cwd!())
      plugins_dir = Path.join(workspace, ".shazam/plugins")
      File.mkdir_p!(plugins_dir)
      tmp_dir = Path.join(System.tmp_dir!(), "shazam-plugin-#{:erlang.system_time(:millisecond)}")

      case System.cmd("gh", ["repo", "clone", repo, tmp_dir], stderr_to_stdout: true) do
        {_, 0} ->
          files = case opts[:path] do
            nil ->
              # Find all .ex files in the cloned repo
              Path.wildcard(Path.join(tmp_dir, "**/*.ex"))
            specific_path ->
              full = Path.join(tmp_dir, specific_path)
              if File.exists?(full), do: [full], else: []
          end

          if files == [] do
            Helpers.send_event(state.port, "system", "error", "No .ex files found#{if opts[:path], do: " at #{opts[:path]}", else: ""}")
          else
            installed = Enum.map(files, fn src ->
              dest_name = Path.basename(src)
              dest = Path.join(plugins_dir, dest_name)
              File.cp!(src, dest)
              dest_name
            end)

            # Reload plugins
            Shazam.PluginManager.reload()

            Helpers.send_event(state.port, "system", "info", "Installed #{length(installed)} plugin(s):")
            Enum.each(installed, fn name ->
              Helpers.send_event(state.port, "system", "info", "  + #{name}")
            end)
          end

          # Clean up temp dir
          File.rm_rf!(tmp_dir)

        {output, _code} ->
          Helpers.send_event(state.port, "system", "error", "Failed to clone #{repo}: #{String.slice(output, 0..200)}")
          File.rm_rf(tmp_dir)
      end

      state
    end
  end

  def handle_command("/plugins remove " <> name, state) do
    name = String.trim(name)
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    plugins_dir = Path.join(workspace, ".shazam/plugins")

    # Try exact match first, then with .ex extension
    candidates = [
      Path.join(plugins_dir, name),
      Path.join(plugins_dir, "#{name}.ex")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        Helpers.send_event(state.port, "system", "error", "Plugin '#{name}' not found in .shazam/plugins/")
      path ->
        File.rm!(path)
        Shazam.PluginManager.reload()
        Helpers.send_event(state.port, "system", "info", "Removed plugin: #{Path.basename(path)}")
    end

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

  def handle_command("/restart" <> _rest, state) do
    Helpers.send_event(state.port, "system", "info", "Restarting Shazam...")

    # Stop all running tasks
    company_name = state.company[:name] || state.company.name
    try do
      Shazam.RalphLoop.pause(company_name)
    catch
      _, _ -> :ok
    end

    # Re-run /start
    handle_command("/start", state)
  end

  def handle_command("/github sync", state) do
    company_name = state.company[:name] || state.company.name

    Helpers.send_event(state.port, "system", "info", "Syncing from GitHub...")

    # Re-run plugin on_init to sync from GitHub
    try do
      Shazam.PluginManager.run_pipeline(:on_init, nil, company_name: company_name)
      # Show plugin log
      show_plugin_log(state)
    catch
      _, _ ->
        Helpers.send_event(state.port, "system", "error", "GitHub sync failed")
    end

    state
  end

  def handle_command("/health", state) do
    lines = []

    # Running agents with last activity time
    company_name = Helpers.deep_get(state, [:company, :name]) || ""
    running_info = if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      try do
        case Shazam.RalphLoop.status(company_name) do
          %{running_tasks: tasks} when is_list(tasks) -> tasks
          _ -> []
        end
      catch
        _, _ -> []
      end
    else
      []
    end

    lines = lines ++ ["Health Check", ""]

    # Running agents
    lines = lines ++ ["Running Agents:"]
    lines = if running_info == [] do
      lines ++ ["  (none)"]
    else
      Enum.reduce(running_info, lines, fn task_info, acc ->
        agent = task_info[:agent] || task_info.agent
        started = task_info[:started_at] || task_info.started_at
        elapsed = DateTime.diff(DateTime.utc_now(), started, :second)
        stalled = try do
          Shazam.AgentPulse.stalled?(agent)
        catch
          _, _ -> false
        end
        stall_marker = if stalled, do: " [STALLED]", else: ""
        acc ++ ["  #{agent}: running #{elapsed}s#{stall_marker}"]
      end)
    end

    # Stalled agents (>30s no activity)
    stalled_agents = Enum.filter(running_info, fn task_info ->
      agent = task_info[:agent] || task_info.agent
      try do
        Shazam.AgentPulse.stalled?(agent)
      catch
        _, _ -> false
      end
    end)

    lines = lines ++ ["", "Stalled Agents (>30s no activity):"]
    lines = if stalled_agents == [] do
      lines ++ ["  (none)"]
    else
      Enum.reduce(stalled_agents, lines, fn task_info, acc ->
        agent = task_info[:agent] || task_info.agent
        acc ++ ["  #{agent}"]
      end)
    end

    # Circuit breaker status
    cb_status = try do
      Shazam.CircuitBreaker.status()
    catch
      _, _ -> %{consecutive_failures: 0, tripped: false, last_error: nil, threshold: 3}
    end

    cb_state = if cb_status.tripped, do: "TRIPPED", else: "OK"
    lines = lines ++ [
      "",
      "Circuit Breaker: #{cb_state}",
      "  Consecutive failures: #{cb_status.consecutive_failures}/#{cb_status.threshold}"
    ]
    if cb_status.last_error do
      lines = lines ++ ["  Last error: #{inspect(cb_status.last_error, limit: 100)}"]
      _ = lines
    end

    # Memory usage
    mem = :erlang.memory()
    total_mb = div(mem[:total], 1_048_576)
    lines = lines ++ [
      "",
      "Resources:",
      "  BEAM Memory: #{total_mb} MB",
      "  Processes: #{:erlang.system_info(:process_count)}"
    ]

    # Disk usage for .shazam directory
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    shazam_dir = Path.join(workspace, ".shazam")
    disk_info = try do
      case System.cmd("df", ["-h", shazam_dir], stderr_to_stdout: true) do
        {output, 0} ->
          df_lines = String.split(output, "\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
          case df_lines do
            [line | _] ->
              parts = String.split(line)
              capacity = Enum.find(parts, fn p -> String.ends_with?(p, "%") end) || "?"
              avail = Enum.at(parts, 3) || "?"
              "#{capacity} used, #{avail} available"
            _ -> "unknown"
          end
        _ -> "unknown"
      end
    catch
      _, _ -> "unknown"
    end
    lines = lines ++ ["  Disk (.shazam): #{disk_info}"]

    Enum.each(lines, fn line ->
      Helpers.send_event(state.port, "system", "info", line)
    end)
    state
  end

  # ── Private helpers ────────────────────────────────────────

  defp parse_plugin_install_args(args) do
    parts = String.split(String.trim(args))
    case parts do
      [repo, "--path", path | _] -> {repo, [path: path]}
      [repo | _] -> {repo, []}
      [] -> {"", []}
    end
  end

  defp show_plugin_log(state) do
    log_path = "/tmp/shazam-plugin.log"
    case File.read(log_path) do
      {:ok, content} when content != "" ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(fn line ->
          Helpers.send_event(state.port, "plugin", "info", line)
        end)
        File.write(log_path, "")
      _ -> :ok
    end
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

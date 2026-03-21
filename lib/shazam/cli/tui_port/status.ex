defmodule Shazam.CLI.TuiPort.Status do
  @moduledoc """
  Status reporting and dashboard data for TuiPort.
  """

  alias Shazam.CLI.TuiPort.Helpers

  def send_status(state) do
    {agents_total, agents_active} = get_agent_counts(state)
    {pending, running, done, awaiting} = get_task_counts(state)
    {budget_used, budget_total} = get_budget_info(state)
    company_name = Helpers.deep_get(state, [:company, :name]) || "Shazam"
    ralph_status = get_ralph_status(state)

    # Memory: BEAM + child processes (claude, codex, cursor, etc.)
    beam_mem = :erlang.memory(:total)
    children_mem = get_children_memory()
    memory_mb = div(beam_mem + children_mem, 1_048_576)

    # Get sparklines for active agents
    sparklines = try do
      Shazam.AgentPulse.all_sparklines()
    catch
      _, _ -> %{}
    end

    # Get total cost across all agents
    total_cost = try do
      case Shazam.Metrics.get_all() do
        %{totals: %{estimated_cost: cost}} when is_number(cost) -> cost
        _ -> 0.0
      end
    catch
      _, _ -> 0.0
    end

    # Get git branch and status
    workspace = Application.get_env(:shazam, :workspace)

    git_branch = try do
      Shazam.GitContext.current_branch(workspace)
    catch
      _, _ -> ""
    end

    git_status = try do
      case Shazam.GitContext.modified_files(workspace) do
        [] -> "clean"
        files when is_list(files) -> "#{length(files)} modified"
      end
    catch
      _, _ -> "unknown"
    end

    # Get current default provider
    provider = try do
      to_string(Application.get_env(:shazam, :default_provider, "claude_code"))
    catch
      _, _ -> "claude_code"
    end

    Helpers.send_json(state.port, %{
      type: "status",
      company: company_name,
      status: ralph_status,
      agents_total: agents_total,
      agents_active: agents_active,
      tasks_pending: pending,
      tasks_running: running,
      tasks_done: done,
      tasks_awaiting: awaiting,
      budget_used: budget_used,
      budget_total: budget_total,
      memory_mb: memory_mb,
      sparklines: sparklines,
      total_cost: total_cost,
      git_branch: git_branch,
      git_status: git_status,
      provider: provider
    })
  end

  def get_agent_counts(state) do
    agents = Helpers.deep_get(state, [:company, :agents]) || []
    total = length(agents)
    # Count agents with active sessions from metrics
    active = if Code.ensure_loaded?(Shazam.Metrics) do
      agents
      |> Enum.count(fn a ->
        name = a[:name] || a.name
        case Shazam.Metrics.get_agent(name) do
          %{status: s} when s in ["working", "thinking"] -> true
          _ -> false
        end
      end)
    else
      0
    end
    {total, active}
  catch
    :exit, _ -> {0, 0}
    _, _ -> {0, 0}
  end

  def get_task_counts(state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      tasks = Helpers.list_tasks(state)
      awaiting = Enum.count(tasks, &(normalize_status(&1.status) == "awaiting_approval"))
      pending = Enum.count(tasks, &(normalize_status(&1.status) == "pending"))
      running = Enum.count(tasks, &(normalize_status(&1.status) in ["in_progress", "running"]))
      done = Enum.count(tasks, &(normalize_status(&1.status) in ["completed", "failed"]))
      {pending, running, done, awaiting}
    else
      {0, 0, 0, 0}
    end
  catch
    :exit, _ -> {0, 0, 0, 0}
    _, _ -> {0, 0, 0, 0}
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: ""

  def get_budget_info(state) do
    agents = Helpers.deep_get(state, [:company, :agents]) || []
    total = agents |> Enum.map(& &1[:budget] || 100_000) |> Enum.sum()
    used = if Code.ensure_loaded?(Shazam.Metrics) do
      agents
      |> Enum.reduce(0, fn a, acc ->
        name = a[:name] || a.name
        case Shazam.Metrics.get_agent(name) do
          %{tokens_used: t} when is_integer(t) -> acc + t
          _ -> acc
        end
      end)
    else
      0
    end
    {used, total}
  catch
    :exit, _ -> {0, 0}
    _, _ -> {0, 0}
  end

  def get_ralph_status(state) do
    company_name = Helpers.deep_get(state, [:company, :name]) || ""
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.status(company_name) do
        %{paused: false} -> "running"
        %{paused: true} -> "paused"
        _ -> "idle"
      end
    else
      "idle"
    end
  catch
    :exit, _ -> "idle"
    _, _ -> "idle"
  end

  defp get_children_memory do
    # Sum RSS of child processes (claude, codex, cursor, gemini, node, etc.)
    beam_pid = :os.getpid() |> to_string()
    try do
      {output, 0} = System.cmd("ps", ["-o", "rss=", "--ppid", beam_pid], stderr_to_stdout: true)
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
      |> Enum.sum()
      |> Kernel.*(1024)  # ps reports in KB, convert to bytes
    rescue
      _ -> get_children_memory_macos(beam_pid)
    catch
      _, _ -> get_children_memory_macos(beam_pid)
    end
  end

  # macOS ps doesn't support --ppid
  defp get_children_memory_macos(beam_pid) do
    try do
      {output, 0} = System.cmd("pgrep", ["-P", beam_pid], stderr_to_stdout: true)
      child_pids = output |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      if child_pids == [] do
        0
      else
        {ps_output, 0} = System.cmd("ps", ["-o", "rss=" | child_pids], stderr_to_stdout: true)
        ps_output
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.reduce(0, fn s, acc ->
          case Integer.parse(s) do
            {n, _} -> acc + n
            :error -> acc
          end
        end)
        |> Kernel.*(1024)
      end
    catch
      _, _ -> 0
    end
  end

  def build_dashboard_data(state) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    Enum.map(agents, fn agent ->
      name = agent[:name] || Map.get(agent, :name, "unknown")
      metrics = if Code.ensure_loaded?(Shazam.Metrics) do
        try do
          Shazam.Metrics.get_agent(name) || %{}
        catch
          _, _ -> %{}
        end
      else
        %{}
      end

      current_task = if Code.ensure_loaded?(Shazam.TaskBoard) do
        try do
          case Helpers.list_tasks(state) |> Enum.find(&(&1.assigned_to == name && normalize_status(&1.status) in ["in_progress", "running"])) do
            nil -> nil
            t -> t.title
          end
        catch
          _, _ -> nil
        end
      end

      %{
        name: name,
        role: agent[:role],
        status: Map.get(metrics, :status, "idle"),
        domain: agent[:domain],
        supervisor: agent[:supervisor],
        tasks_completed: Map.get(metrics, :tasks_completed, 0),
        tasks_failed: Map.get(metrics, :tasks_failed, 0),
        tokens_used: Map.get(metrics, :tokens_used, 0),
        budget: agent[:budget],
        current_task: current_task
      }
    end)
  rescue
    e ->
      if function_exported?(Logger, :warning, 1) do
        require Logger
        Logger.warning("[Dashboard] Error building data: #{inspect(e)}")
      end
      []
  end
end

defmodule Shazam.CLI.TuiPort.Status do
  @moduledoc """
  Status reporting and dashboard data for TuiPort.
  """

  alias Shazam.CLI.TuiPort.Helpers

  def send_status(state) do
    {agents_total, agents_active} = get_agent_counts(state)
    {pending, running, done, awaiting} = get_task_counts()
    {budget_used, budget_total} = get_budget_info(state)
    company_name = Helpers.deep_get(state, [:company, :name]) || "Shazam"
    ralph_status = get_ralph_status(state)

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
      budget_total: budget_total
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

  def get_task_counts do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      tasks = Shazam.TaskBoard.list()
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
          case Shazam.TaskBoard.list() |> Enum.find(&(&1.assigned_to == name && normalize_status(&1.status) in ["in_progress", "running"])) do
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

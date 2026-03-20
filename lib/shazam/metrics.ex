defmodule Shazam.Metrics do
  @moduledoc """
  In-memory metrics tracking for Shazam agents.

  Tracks per-agent: success/failure counts, average execution time,
  total tokens consumed, estimated cost, and tasks-per-hour rate.

  Uses ETS for fast concurrent reads. Broadcasts updates via EventBus.
  """

  use GenServer
  require Logger

  @table :shazam_metrics
  @cost_per_1k_tokens 0.003

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a successful task completion for an agent.

  - `agent` — agent name (string)
  - `duration_ms` — how long the task took in milliseconds
  - `tokens` — number of tokens consumed (0 if unknown)
  """
  def record_completion(agent, duration_ms, tokens \\ 0) do
    GenServer.cast(__MODULE__, {:record_completion, agent, duration_ms, tokens})
  end

  @doc "Records a task failure for an agent."
  def record_failure(agent) do
    GenServer.cast(__MODULE__, {:record_failure, agent})
  end

  @doc "Records token usage and cost for an agent."
  def record_tokens(agent, tokens, cost_usd \\ 0.0) do
    GenServer.cast(__MODULE__, {:record_tokens, agent, tokens, cost_usd})
  end

  def set_status(agent, status) do
    GenServer.cast(__MODULE__, {:set_status, agent, status})
  end

  @doc "Resets all metrics."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Fully clears all metrics (for tests)."
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @doc "Returns metrics for all agents as a map."
  def get_all do
    GenServer.call(__MODULE__, :get_all)
  end

  @doc "Returns metrics for a single agent."
  def get_agent(name) do
    GenServer.call(__MODULE__, {:get_agent, name})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.insert(table, {:__started_at, System.monotonic_time(:millisecond)})

    # Restore saved metrics from disk
    load_metrics(table)

    Logger.info("[Metrics] Started")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:record_completion, agent, duration_ms, tokens}, state) do
    now = System.monotonic_time(:millisecond)
    update_agent(agent, fn metrics ->
      total_duration = metrics.total_duration_ms + duration_ms
      successes = metrics.successes + 1
      total_tasks = successes + metrics.failures
      new_tokens = metrics.total_tokens + tokens

      %{metrics |
        successes: successes,
        total_duration_ms: total_duration,
        avg_duration_ms: div(total_duration, successes),
        total_tokens: new_tokens,
        estimated_cost: Float.round(new_tokens / 1000 * @cost_per_1k_tokens, 4),
        last_completed_at: now,
        tasks_per_hour: compute_tasks_per_hour(total_tasks, metrics.first_task_at || now, now)
      }
    end)

    broadcast_metrics_update()
    {:noreply, state}
  end

  def handle_cast({:record_failure, agent}, state) do
    now = System.monotonic_time(:millisecond)
    update_agent(agent, fn metrics ->
      failures = metrics.failures + 1
      total_tasks = metrics.successes + failures

      %{metrics |
        failures: failures,
        tasks_per_hour: compute_tasks_per_hour(total_tasks, metrics.first_task_at || now, now)
      }
    end)

    broadcast_metrics_update()
    {:noreply, state}
  end

  def handle_cast({:record_tokens, agent, tokens, cost_usd}, state) do
    update_agent(agent, fn metrics ->
      %{metrics |
        total_tokens: metrics.total_tokens + tokens,
        cost_usd: Float.round((metrics.cost_usd || 0.0) + cost_usd, 6)
      }
    end)
    # Save metrics to disk
    save_metrics()
    {:noreply, state}
  end

  def handle_cast({:set_status, agent, status}, state) do
    update_agent(agent, fn metrics ->
      %{metrics | status: status}
    end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Reset session metrics but preserve cumulative token/cost data
    now = System.monotonic_time(:millisecond)
    :ets.tab2list(@table)
    |> Enum.each(fn
      {:__started_at, _} -> :ok
      {agent, metrics} ->
        # Keep tokens and cost, reset session counters
        :ets.insert(@table, {agent, %{default_metrics(now) |
          total_tokens: metrics.total_tokens || 0,
          input_tokens: metrics[:input_tokens] || 0,
          output_tokens: metrics[:output_tokens] || 0,
          cost_usd: metrics[:cost_usd] || 0.0,
          successes: metrics.successes || 0,
          failures: metrics.failures || 0
        }})
    end)
    :ets.insert(@table, {:__started_at, now})
    {:reply, :ok, state}
  end

  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {:__started_at, now})
    {:reply, :ok, state}
  end

  def handle_call(:get_all, _from, state) do
    agents =
      :ets.tab2list(@table)
      |> Enum.reject(fn {key, _} -> key == :__started_at end)
      |> Enum.map(fn {agent_name, metrics} ->
        {agent_name, serialize_metrics(metrics)}
      end)
      |> Map.new()

    totals = compute_totals(agents)
    {:reply, %{agents: agents, totals: totals}, state}
  end

  def handle_call({:get_agent, name}, _from, state) do
    result =
      case :ets.lookup(@table, name) do
        [{^name, metrics}] -> serialize_metrics(metrics)
        [] -> nil
      end

    {:reply, result, state}
  end

  # --- Internal ---

  defp default_metrics(now) do
    %{
      successes: 0,
      failures: 0,
      total_duration_ms: 0,
      avg_duration_ms: 0,
      total_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: 0.0,
      estimated_cost: 0.0,
      tasks_per_hour: 0.0,
      first_task_at: now,
      last_completed_at: nil,
      status: "idle"
    }
  end

  defp update_agent(agent, update_fn) do
    now = System.monotonic_time(:millisecond)

    current =
      case :ets.lookup(@table, agent) do
        [{^agent, metrics}] -> metrics
        [] -> default_metrics(now)
      end

    updated = update_fn.(current)
    :ets.insert(@table, {agent, updated})
  end

  defp compute_tasks_per_hour(total_tasks, first_task_at, now) do
    elapsed_hours = max((now - first_task_at) / 3_600_000, 0.001)
    Float.round(total_tasks / elapsed_hours, 2)
  end

  defp serialize_metrics(metrics) do
    %{
      successes: metrics.successes,
      failures: metrics.failures,
      total_tasks: metrics.successes + metrics.failures,
      success_rate: compute_rate(metrics.successes, metrics.successes + metrics.failures),
      avg_duration_ms: metrics.avg_duration_ms,
      total_tokens: metrics.total_tokens,
      estimated_cost: metrics.estimated_cost,
      tasks_per_hour: metrics.tasks_per_hour
    }
  end

  defp compute_rate(_successes, 0), do: 0.0
  defp compute_rate(successes, total), do: Float.round(successes / total * 100, 1)

  defp compute_totals(agents) do
    Enum.reduce(agents, %{successes: 0, failures: 0, total_tokens: 0, estimated_cost: 0.0}, fn {_name, m}, acc ->
      %{
        successes: acc.successes + m.successes,
        failures: acc.failures + m.failures,
        total_tokens: acc.total_tokens + m.total_tokens,
        estimated_cost: Float.round(acc.estimated_cost + m.estimated_cost, 4)
      }
    end)
    |> then(fn totals ->
      total_tasks = totals.successes + totals.failures
      Map.put(totals, :total_tasks, total_tasks)
      |> Map.put(:success_rate, compute_rate(totals.successes, total_tasks))
    end)
  end

  defp broadcast_metrics_update do
    Shazam.API.EventBus.broadcast(%{event: "metrics_updated"})
  end

  defp metrics_file do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    Path.join([workspace, ".shazam", "metrics.json"])
  end

  defp save_metrics do
    spawn(fn ->
      try do
        data = :ets.tab2list(@table)
          |> Enum.reject(fn {key, _} -> key == :__started_at end)
          |> Enum.map(fn {agent, metrics} ->
            {to_string(agent), %{
              total_tokens: metrics.total_tokens || 0,
              input_tokens: metrics[:input_tokens] || 0,
              output_tokens: metrics[:output_tokens] || 0,
              cost_usd: metrics[:cost_usd] || 0.0,
              successes: metrics.successes || 0,
              failures: metrics.failures || 0
            }}
          end)
          |> Map.new()

        path = metrics_file()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(data, pretty: true))
      catch
        _, _ -> :ok
      end
    end)
  end

  defp load_metrics(table) do
    try do
      path = metrics_file()
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} when is_map(data) ->
              now = System.monotonic_time(:millisecond)
              Enum.each(data, fn {agent, metrics} ->
                :ets.insert(table, {agent, %{default_metrics(now) |
                  total_tokens: metrics["total_tokens"] || 0,
                  input_tokens: metrics["input_tokens"] || 0,
                  output_tokens: metrics["output_tokens"] || 0,
                  cost_usd: (metrics["cost_usd"] || 0.0) * 1.0,
                  successes: metrics["successes"] || 0,
                  failures: metrics["failures"] || 0
                }})
              end)
            _ -> :ok
          end
        _ -> :ok
      end
    catch
      _, _ -> :ok
    end
  end
end

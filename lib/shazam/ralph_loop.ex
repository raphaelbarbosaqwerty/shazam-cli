defmodule Shazam.RalphLoop do
  @moduledoc """
  Per-company task execution loop.
  Each company gets its own RalphLoop instance via Registry.

  This module is the GenServer orchestrator. Actual logic is delegated to:
  - `Shazam.TaskScheduler` — task selection, peer reassignment, module locking
  - `Shazam.TaskExecutor` — prompt building and agent task execution
  - `Shazam.SubtaskParser` — parsing and creating subtasks from agent output
  - `Shazam.ModuleManager` — module auto-claim logic
  """

  use GenServer
  require Logger

  alias Shazam.{TaskBoard, TaskScheduler, TaskExecutor, SubtaskParser, ModuleManager, RetryPolicy}

  @poll_interval 5_000
  @default_max_concurrent 4

  defstruct [
    max_concurrent: @default_max_concurrent,
    running: %{},        # %{task_id => %{pid: pid, ref: ref, agent_name: ...}}
    company_name: nil,
    paused: true,         # starts paused — user must explicitly resume from Flutter
    auto_approve: false,  # human-in-the-loop: PM subtasks go to awaiting_approval
    module_lock: true,    # lock modules so only hierarchy members can edit concurrently
    peer_reassign: true,  # reassign tasks to idle peers when assigned agent is busy
    poll_interval: @poll_interval,
    auto_retry: true,     # automatically retry failed tasks with backoff
    max_retries: 2,       # default max retry attempts per task
    status: :idle
  ]

  # --- Public API ---

  @call_timeout :timer.minutes(10)

  def start_link(company_name, opts \\ []) do
    GenServer.start_link(__MODULE__, {company_name, opts}, name: via(company_name))
  end

  @doc "Returns the current loop state."
  def status(company_name) do
    GenServer.call(via(company_name), :status, @call_timeout)
  end

  @doc "Checks if a RalphLoop exists for the given company."
  def exists?(company_name) do
    case Registry.lookup(Shazam.RalphLoopRegistry, company_name) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc "Changes the maximum concurrency."
  def set_max_concurrent(company_name, n) when is_integer(n) and n > 0 do
    GenServer.call(via(company_name), {:set_max_concurrent, n}, @call_timeout)
  end

  @doc "Kills a single running task by task_id."
  def kill_task(company_name, task_id) do
    GenServer.call(via(company_name), {:kill_task, task_id}, @call_timeout)
  end

  @doc "Pauses a single task. If running, kills the process but keeps the session."
  def pause_task(company_name, task_id) do
    GenServer.call(via(company_name), {:pause_task, task_id}, @call_timeout)
  end

  @doc "Resumes a paused task back to pending."
  def resume_task(company_name, task_id) do
    GenServer.call(via(company_name), {:resume_task, task_id}, @call_timeout)
  end

  @doc "Pauses the loop — stops picking new tasks. Running tasks finish normally."
  def pause(company_name) do
    GenServer.call(via(company_name), :pause, @call_timeout)
  end

  @doc "Resumes the loop — starts picking pending tasks again."
  def resume(company_name) do
    GenServer.call(via(company_name), :resume, @call_timeout)
  end

  @doc "Sets auto-approve mode for PM subtasks."
  def set_auto_approve(company_name, enabled) when is_boolean(enabled) do
    GenServer.call(via(company_name), {:set_auto_approve, enabled}, @call_timeout)
  end

  @doc "Updates a config key dynamically."
  def set_config(company_name, key, value) do
    GenServer.call(via(company_name), {:set_config, key, value}, @call_timeout)
  end

  @doc "Pauses all running tasks."
  def pause_all(company_name) do
    GenServer.call(via(company_name), :pause_all, @call_timeout)
  end

  @doc "Stops the RalphLoop for a company."
  def stop(company_name) do
    case Registry.lookup(Shazam.RalphLoopRegistry, company_name) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 10_000)
      [] -> :ok
    end
  end

  # --- Callbacks ---

  @impl true
  def init({company_name, opts}) do
    max = Keyword.get(opts, :max_concurrent, @default_max_concurrent)
    Logger.info("[RalphLoop:#{company_name}] Started | max_concurrent: #{max}")
    Process.send_after(self(), :poll, 5_000)

    {:ok, %__MODULE__{
      company_name: company_name,
      max_concurrent: max,
      status: :running
    }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    running_info =
      state.running
      |> Enum.map(fn {task_id, info} ->
        %{task_id: task_id, agent: info.agent_name, started_at: info.started_at}
      end)

    info = %{
      status: state.status,
      paused: state.paused,
      company: state.company_name,
      running_count: map_size(state.running),
      running_tasks: running_info,
      config: %{
        auto_approve: state.auto_approve,
        auto_retry: state.auto_retry,
        max_retries: state.max_retries,
        max_concurrent: state.max_concurrent,
        module_lock: state.module_lock,
        peer_reassign: state.peer_reassign,
        poll_interval: state.poll_interval
      }
    }

    {:reply, info, state}
  end

  def handle_call({:set_max_concurrent, n}, _from, state) do
    Logger.info("[RalphLoop:#{state.company_name}] max_concurrent changed to #{n}")
    {:reply, :ok, %{state | max_concurrent: n}}
  end

  def handle_call({:kill_task, task_id}, _from, state) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {info, running} ->
        Process.demonitor(info.ref, [:flush])
        Process.exit(info.pid, :kill)
        Shazam.SessionPool.kill(info.agent_name)
        TaskBoard.fail(task_id, "Killed by user")
        Logger.info("[RalphLoop:#{state.company_name}] Killed task #{task_id} (#{info.agent_name})")
        Shazam.API.EventBus.broadcast(%{event: "task_killed", task_id: task_id, agent: info.agent_name})
        {:reply, {:ok, task_id}, %{state | running: running}}
    end
  end

  def handle_call({:pause_task, task_id}, _from, state) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        case TaskBoard.pause(task_id) do
          {:ok, _} ->
            Logger.info("[RalphLoop:#{state.company_name}] Paused pending task #{task_id}")
            Shazam.API.EventBus.broadcast(%{event: "task_paused", task_id: task_id})
            {:reply, {:ok, task_id}, state}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {info, running} ->
        Process.demonitor(info.ref, [:flush])
        Process.exit(info.pid, :kill)
        TaskBoard.pause(task_id)
        Logger.info("[RalphLoop:#{state.company_name}] Paused running task #{task_id} (#{info.agent_name})")
        Shazam.API.EventBus.broadcast(%{event: "task_paused", task_id: task_id, agent: info.agent_name})
        {:reply, {:ok, task_id}, %{state | running: running}}
    end
  end

  def handle_call({:resume_task, task_id}, _from, state) do
    case TaskBoard.resume_task(task_id) do
      {:ok, _} ->
        Logger.info("[RalphLoop:#{state.company_name}] Resumed task #{task_id} -> pending")
        Shazam.API.EventBus.broadcast(%{event: "task_resumed", task_id: task_id})
        {:reply, {:ok, task_id}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, state) do
    Logger.info("[RalphLoop:#{state.company_name}] Paused")
    Shazam.API.EventBus.broadcast(%{event: "ralph_paused", company: state.company_name})
    {:reply, :ok, %{state | paused: true}}
  end

  def handle_call(:resume, _from, state) do
    Logger.info("[RalphLoop:#{state.company_name}] Resumed")
    Shazam.API.EventBus.broadcast(%{event: "ralph_resumed", company: state.company_name})
    {:reply, :ok, %{state | paused: false}}
  end

  def handle_call({:set_auto_approve, enabled}, _from, state) do
    Logger.info("[RalphLoop:#{state.company_name}] Auto-approve set to #{enabled}")
    {:reply, :ok, %{state | auto_approve: enabled}}
  end

  def handle_call({:set_config, key, value}, _from, state) do
    case key do
      "module_lock" when is_boolean(value) ->
        {:reply, :ok, %{state | module_lock: value}}
      "peer_reassign" when is_boolean(value) ->
        {:reply, :ok, %{state | peer_reassign: value}}
      "auto_approve" when is_boolean(value) ->
        {:reply, :ok, %{state | auto_approve: value}}
      "max_concurrent" when is_integer(value) and value > 0 ->
        {:reply, :ok, %{state | max_concurrent: value}}
      "poll_interval" when is_integer(value) and value >= 1000 ->
        {:reply, :ok, %{state | poll_interval: value}}
      "auto_retry" when is_boolean(value) ->
        {:reply, :ok, %{state | auto_retry: value}}
      "max_retries" when is_integer(value) and value >= 0 ->
        {:reply, :ok, %{state | max_retries: value}}
      _ ->
        {:reply, {:error, :invalid_config}, state}
    end
  end

  def handle_call(:pause_all, _from, state) do
    paused =
      state.running
      |> Enum.map(fn {task_id, info} ->
        Process.demonitor(info.ref, [:flush])
        Process.exit(info.pid, :kill)
        TaskBoard.pause(task_id)
        Logger.info("[RalphLoop:#{state.company_name}] Paused task #{task_id} (#{info.agent_name})")
        task_id
      end)

    Shazam.API.EventBus.broadcast(%{event: "all_tasks_paused", count: length(paused), company: state.company_name})
    {:reply, {:ok, paused}, %{state | running: %{}, paused: true}}
  end

  @impl true
  def handle_info(:poll, %{paused: true} = state) do
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    state = maybe_pick_tasks(state)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # Result of a completed task
  def handle_info({:task_done, task_id, result}, state) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        {:noreply, state}

      {info, running} ->
        Process.demonitor(info.ref, [:flush])
        duration_ms = DateTime.diff(DateTime.utc_now(), info.started_at, :millisecond)

        case result do
          {:ok, output, touched_files} ->
            TaskBoard.complete(task_id, output)
            Logger.info("[RalphLoop:#{state.company_name}] Task #{task_id} completed by #{info.agent_name}")
            Shazam.FileLogger.info("Task #{task_id} completed by #{info.agent_name}")
            Shazam.Metrics.record_completion(info.agent_name, duration_ms)
            ModuleManager.auto_claim_modules(state.company_name, info.agent_name, touched_files)
            SubtaskParser.maybe_create_subtasks(task_id, info.agent_name, output, state.company_name, state.auto_approve)
            unblock_dependents(task_id)
            Shazam.API.EventBus.broadcast(%{
              event: "task_completed",
              task_id: task_id,
              agent: info.agent_name,
              company: state.company_name
            })

            # Process queued user messages
            if Shazam.AgentInbox.has_pending?(info.agent_name) do
              spawn(fn -> Shazam.AgentInbox.execute_pending(info.agent_name) end)
            end

          {:ok, output} ->
            TaskBoard.complete(task_id, output)
            Logger.info("[RalphLoop:#{state.company_name}] Task #{task_id} completed by #{info.agent_name}")
            Shazam.FileLogger.info("Task #{task_id} completed by #{info.agent_name}")
            Shazam.Metrics.record_completion(info.agent_name, duration_ms)
            SubtaskParser.maybe_create_subtasks(task_id, info.agent_name, output, state.company_name, state.auto_approve)
            unblock_dependents(task_id)
            Shazam.API.EventBus.broadcast(%{
              event: "task_completed",
              task_id: task_id,
              agent: info.agent_name,
              company: state.company_name
            })

            if Shazam.AgentInbox.has_pending?(info.agent_name) do
              spawn(fn -> Shazam.AgentInbox.execute_pending(info.agent_name) end)
            end

          {:error, reason} ->
            Shazam.Metrics.record_failure(info.agent_name)
            Shazam.FileLogger.warn("Task #{task_id} failed: #{inspect(reason, limit: 200)}")
            maybe_auto_retry(task_id, reason, info.agent_name, state)
        end

        {:noreply, %{state | running: running}}
    end
  end

  # If the task process dies unexpectedly
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_id, info} -> info.ref == ref end) do
      {task_id, info} ->
        task = case TaskBoard.get(task_id) do
          {:ok, t} -> t
          _ -> nil
        end
        if task && task.status == :paused do
          Logger.debug("[RalphLoop:#{state.company_name}] Task #{task_id} process exited (paused)")
        else
          Logger.error("[RalphLoop:#{state.company_name}] Task #{task_id} died: #{inspect(reason)}")
          Shazam.Metrics.record_failure(info.agent_name)
          maybe_auto_retry(task_id, {:process_died, reason}, info.agent_name, state)
        end
        {:noreply, %{state | running: Map.delete(state.running, task_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_task, task_id}, state) do
    Logger.info("[RalphLoop:#{state.company_name}] Retry timer fired for task #{task_id}")
    {:noreply, state}
  end

  # --- Main logic ---

  defp maybe_pick_tasks(state) do
    available_slots = state.max_concurrent - map_size(state.running)

    if available_slots <= 0 do
      state
    else
      # Only fetch tasks for THIS company
      pending = TaskBoard.list(%{status: :pending, company: state.company_name})

      candidates =
        pending
        |> Enum.reject(fn task -> TaskScheduler.task_blocked?(task) end)
        |> Enum.reject(fn task -> Map.has_key?(state.running, task.id) end)

      locked = if state.module_lock, do: TaskScheduler.locked_module_paths(state.running, state.company_name), else: %{}

      TaskScheduler.pick_tasks(candidates, state, locked, available_slots, &execute_task/2)
    end
  end

  defp execute_task(state, task) do
    agent_profile = TaskScheduler.resolve_agent_profile(state.company_name, task.assigned_to)

    unless agent_profile do
      Logger.warning("[RalphLoop:#{state.company_name}] Agent '#{task.assigned_to}' not found, skipping task #{task.id}")
      state
    else
      # Check budget before executing
      tokens_used = get_agent_tokens(agent_profile.name)
      if tokens_used >= agent_profile.budget do
        Logger.warning("[RalphLoop:#{state.company_name}] Agent '#{agent_profile.name}' exceeded budget (#{tokens_used}/#{agent_profile.budget} tokens) — skipping task #{task.id}")
        Shazam.FileLogger.warn("Budget exceeded: agent=#{agent_profile.name} used=#{tokens_used} budget=#{agent_profile.budget} task=#{task.id}")
        TaskBoard.fail(task.id, "Agent budget exceeded (#{tokens_used}/#{agent_profile.budget} tokens)")
        Shazam.API.EventBus.broadcast(%{
          event: "task_failed",
          task_id: task.id,
          agent: agent_profile.name,
          reason: "Budget exceeded"
        })
        state
      else
      case TaskBoard.checkout(task.id, task.assigned_to) do
        {:ok, checked_task} ->
          Logger.info("[RalphLoop:#{state.company_name}] Executing task #{task.id} with agent '#{task.assigned_to}'")

          Shazam.API.EventBus.broadcast(%{
            event: "task_started",
            task_id: task.id,
            agent: task.assigned_to,
            company: state.company_name
          })

          loop_pid = self()

          {pid, ref} = spawn_monitor(fn ->
            result = TaskExecutor.run_agent_task(agent_profile, checked_task, state.company_name)
            send(loop_pid, {:task_done, task.id, result})
          end)

          running_info = %{
            pid: pid,
            ref: ref,
            agent_name: task.assigned_to,
            started_at: DateTime.utc_now()
          }

          %{state | running: Map.put(state.running, task.id, running_info)}

        {:error, reason} ->
          Logger.debug("[RalphLoop:#{state.company_name}] Could not checkout #{task.id}: #{inspect(reason)}")
          state
      end
      end
    end
  end

  defp maybe_auto_retry(task_id, reason, agent_name, state) do
    if state.auto_retry do
      case TaskBoard.get(task_id) do
        {:ok, task} ->
          task = Map.put_new(task, :max_retries, state.max_retries)
          task = Map.put_new(task, :retry_count, 0)
          task = Map.put(task, :last_error, reason)

          if RetryPolicy.should_retry?(task) do
            retry_count = Map.get(task, :retry_count, 0)
            delay = RetryPolicy.next_delay(retry_count)
            Logger.info("[RalphLoop:#{state.company_name}] Task #{task_id} will auto-retry in #{delay}ms")
            TaskBoard.increment_retry(task_id, reason)
            Process.send_after(self(), {:retry_task, task_id}, delay)

            Shazam.API.EventBus.broadcast(%{
              event: "task_retry_scheduled",
              task_id: task_id,
              agent: agent_name,
              retry_count: retry_count + 1,
              delay_ms: delay,
              reason: inspect(reason, limit: 200)
            })
          else
            TaskBoard.fail(task_id, reason)
            Logger.warning("[RalphLoop:#{state.company_name}] Task #{task_id} failed permanently")
            Shazam.API.EventBus.broadcast(%{
              event: "task_failed",
              task_id: task_id,
              agent: agent_name,
              reason: inspect(reason, limit: 200)
            })
          end

        _ ->
          Logger.warning("[RalphLoop:#{state.company_name}] Task #{task_id} not found for retry")
      end
    else
      TaskBoard.fail(task_id, reason)
      Shazam.API.EventBus.broadcast(%{
        event: "task_failed",
        task_id: task_id,
        agent: agent_name,
        reason: inspect(reason, limit: 200)
      })
    end
  end

  defp unblock_dependents(completed_task_id) do
    Logger.debug("[RalphLoop] Checking dependents of #{completed_task_id}")
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp via(company_name), do: {:via, Registry, {Shazam.RalphLoopRegistry, company_name}}

  defp get_agent_tokens(agent_name) do
    case Shazam.Metrics.get_agent(agent_name) do
      %{total_tokens: tokens} -> tokens
      _ -> 0
    end
  catch
    _, _ -> 0
  end
end

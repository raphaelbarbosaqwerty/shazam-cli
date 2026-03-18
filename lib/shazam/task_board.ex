defmodule Shazam.TaskBoard do
  @moduledoc """
  Task system with atomic checkout using ETS.
  Each task has goal ancestry — the agent knows the what and the why.
  Automatically persists to disk via Shazam.Store.
  """

  use GenServer
  require Logger

  alias Shazam.Store

  @type status :: :pending | :in_progress | :completed | :failed | :awaiting_approval | :paused
  @type task :: %{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          status: status(),
          assigned_to: String.t() | nil,
          created_by: String.t() | nil,
          parent_task_id: String.t() | nil,
          depends_on: String.t() | nil,
          company: String.t() | nil,
          result: any(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @save_debounce 1_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Creates a new task and returns its ID."
  @call_timeout :timer.minutes(10)

  def create(attrs) do
    GenServer.call(__MODULE__, {:create, attrs}, @call_timeout)
  end

  @doc "Atomic checkout — assigns the task to the agent if it is still pending."
  def checkout(task_id, agent_name) do
    GenServer.call(__MODULE__, {:checkout, task_id, agent_name}, @call_timeout)
  end

  @doc "Marks task as completed with result."
  def complete(task_id, result) do
    GenServer.call(__MODULE__, {:complete, task_id, result}, @call_timeout)
  end

  @doc "Marks task as failed."
  def fail(task_id, reason) do
    GenServer.call(__MODULE__, {:fail, task_id, reason}, @call_timeout)
  end

  @doc "Lists tasks. Optional filters: :status, :assigned_to"
  def list(filters \\ %{}) do
    GenServer.call(__MODULE__, {:list, filters}, @call_timeout)
  end

  @doc "Fetches pending tasks assigned to an agent."
  def pending_for(agent_name) do
    list(%{assigned_to: agent_name, status: :pending})
  end

  @doc "Fetches in-progress tasks for an agent."
  def in_progress_for(agent_name) do
    list(%{assigned_to: agent_name, status: :in_progress})
  end

  @doc "Creates a task with :awaiting_approval status."
  def create_awaiting(attrs) do
    GenServer.call(__MODULE__, {:create_awaiting, attrs}, @call_timeout)
  end

  @doc "Approves a task (awaiting_approval → pending)."
  def approve(task_id) do
    GenServer.call(__MODULE__, {:approve, task_id}, @call_timeout)
  end

  @doc "Rejects a task (awaiting_approval → rejected)."
  def reject(task_id, reason \\ "Rejected by user") do
    GenServer.call(__MODULE__, {:reject, task_id, reason}, @call_timeout)
  end

  @doc "Pauses a task (in_progress → paused, or pending → paused)."
  def pause(task_id) do
    GenServer.call(__MODULE__, {:pause, task_id}, @call_timeout)
  end

  @doc "Resumes a paused task (paused → pending)."
  def resume_task(task_id) do
    GenServer.call(__MODULE__, {:resume_task, task_id}, @call_timeout)
  end

  @doc "Re-enqueues a failed task (failed → pending)."
  def retry(task_id) do
    GenServer.call(__MODULE__, {:retry, task_id}, @call_timeout)
  end

  @doc "Increments retry_count, stores last_error, and resets status to pending for automatic retry."
  def increment_retry(task_id, error \\ nil) do
    GenServer.call(__MODULE__, {:increment_retry, task_id, error}, @call_timeout)
  end

  @doc "Soft-deletes a task (marks as :deleted with timestamp, keeps in store)."
  def delete(task_id) do
    GenServer.call(__MODULE__, {:delete, task_id}, @call_timeout)
  end

  @doc "Permanently removes a task from store."
  def purge(task_id) do
    GenServer.call(__MODULE__, {:purge, task_id}, @call_timeout)
  end

  @doc "Restores a soft-deleted task back to pending."
  def restore(task_id) do
    GenServer.call(__MODULE__, {:restore, task_id}, @call_timeout)
  end

  @doc "Clears all tasks from the board."
  def clear_all do
    GenServer.call(__MODULE__, :clear_all, @call_timeout)
  end

  @doc "Reassigns a pending task to a different agent."
  def reassign(task_id, new_agent) do
    GenServer.call(__MODULE__, {:reassign, task_id, new_agent}, @call_timeout)
  end

  @doc "Fetches a task by ID."
  def get(task_id) do
    GenServer.call(__MODULE__, {:get, task_id}, @call_timeout)
  end

  @doc "Returns the goal ancestry of a task (chain of parent tasks)."
  def goal_ancestry(task_id) do
    GenServer.call(__MODULE__, {:goal_ancestry, task_id}, @call_timeout)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:shazam_tasks, [:set, :protected, read_concurrency: true])
    counter = load_tasks(table)
    Logger.info("[TaskBoard] Started with #{counter} task(s) restored from disk")
    {:ok, %{table: table, counter: counter, save_timer: nil}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    id = "task_#{state.counter + 1}"
    now = DateTime.utc_now()

    task = %{
      id: id,
      title: attrs[:title] || "Untitled",
      description: attrs[:description],
      status: :pending,
      assigned_to: attrs[:assigned_to],
      created_by: attrs[:created_by],
      parent_task_id: attrs[:parent_task_id],
      depends_on: attrs[:depends_on],
      company: attrs[:company],
      result: nil,
      attachments: attrs[:attachments] || [],
      retry_count: attrs[:retry_count] || 0,
      max_retries: attrs[:max_retries] || 2,
      last_error: nil,
      created_at: now,
      updated_at: now
    }

    :ets.insert(state.table, {id, task})
    Logger.info("[TaskBoard] Task created: #{id} - #{task.title}")
    broadcast(:task_created, task)

    {:reply, {:ok, task}, %{state | counter: state.counter + 1} |> schedule_save()}
  end

  def handle_call({:create_awaiting, attrs}, _from, state) do
    id = "task_#{state.counter + 1}"
    now = DateTime.utc_now()

    task = %{
      id: id,
      title: attrs[:title] || "Untitled",
      description: attrs[:description],
      status: :awaiting_approval,
      assigned_to: attrs[:assigned_to],
      created_by: attrs[:created_by],
      parent_task_id: attrs[:parent_task_id],
      depends_on: attrs[:depends_on],
      company: attrs[:company],
      result: nil,
      attachments: attrs[:attachments] || [],
      retry_count: attrs[:retry_count] || 0,
      max_retries: attrs[:max_retries] || 2,
      last_error: nil,
      created_at: now,
      updated_at: now
    }

    :ets.insert(state.table, {id, task})
    Logger.info("[TaskBoard] Task created (awaiting approval): #{id} - #{task.title}")
    broadcast(:task_awaiting_approval, task)

    {:reply, {:ok, task}, %{state | counter: state.counter + 1} |> schedule_save()}
  end

  def handle_call({:approve, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :awaiting_approval} = task}] ->
        updated = %{task | status: :pending, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} approved → pending")
        broadcast(:task_approved, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_awaiting_approval, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:reject, task_id, reason}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :awaiting_approval} = task}] ->
        updated = %{task | status: :rejected, result: reason, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} rejected: #{reason}")
        broadcast(:task_rejected, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_awaiting_approval, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:checkout, task_id, agent_name}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :pending} = task}] ->
        updated = %{task | status: :in_progress, assigned_to: agent_name, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] #{agent_name} checked out #{task_id}")
        broadcast(:task_checkout, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:already_taken, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:complete, task_id, result}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :in_progress} = task}] ->
        updated = %{task | status: :completed, result: result, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} completed")
        broadcast(:task_completed, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, _}] ->
        {:reply, {:error, :not_in_progress}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:fail, task_id, reason}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, task}] ->
        updated = %{task | status: :failed, result: {:error, reason}, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.warning("[TaskBoard] Task #{task_id} failed: #{inspect(reason)}")
        broadcast(:task_failed, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:pause, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: status} = task}] when status in [:pending, :in_progress] ->
        updated = %{task | status: :paused, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} paused (was #{status})")
        broadcast(:task_paused, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_pausable, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:resume_task, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :paused} = task}] ->
        updated = %{task | status: :pending, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} resumed → pending")
        broadcast(:task_resumed, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_paused, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:retry, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: status} = task}] when status in [:failed, :completed, :rejected] ->
        updated = %{task | status: :pending, result: nil, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} re-queued → pending")
        broadcast(:task_retried, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_retryable, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:increment_retry, task_id, error}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, task}] ->
        retry_count = Map.get(task, :retry_count, 0) + 1
        max_retries = Map.get(task, :max_retries, 2)

        updated =
          task
          |> Map.put(:retry_count, retry_count)
          |> Map.put(:max_retries, max_retries)
          |> Map.put(:last_error, error)
          |> Map.put(:status, :pending)
          |> Map.put(:result, nil)
          |> Map.put(:updated_at, DateTime.utc_now())

        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} retry #{retry_count}/#{max_retries} → pending")
        broadcast(:task_retried, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, task}] ->
        updated = task
          |> Map.put(:status, :deleted)
          |> Map.put(:deleted_at, DateTime.utc_now())
          |> Map.put(:updated_at, DateTime.utc_now())
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} soft-deleted")
        broadcast(:task_deleted, updated)
        {:reply, :ok, schedule_save(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:purge, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, _task}] ->
        :ets.delete(state.table, task_id)
        Logger.info("[TaskBoard] Task #{task_id} permanently purged")
        {:reply, :ok, schedule_save(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear_all, _from, state) do
    count = :ets.info(state.table, :size)
    :ets.delete_all_objects(state.table)
    # Cancel pending save timer
    if state.save_timer, do: Process.cancel_timer(state.save_timer)
    state = %{state | counter: 0, save_timer: nil}
    # Immediately wipe persisted tasks from disk
    Store.list_keys("tasks:")
    |> Enum.each(fn key -> Store.delete(key) end)
    Store.delete("tasks")
    Logger.info("[TaskBoard] All #{count} tasks cleared (disk wiped)")
    {:reply, {:ok, count}, state}
  end

  def handle_call({:restore, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :deleted} = task}] ->
        updated = task
          |> Map.put(:status, :pending)
          |> Map.put(:deleted_at, nil)
          |> Map.put(:updated_at, DateTime.utc_now())
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} restored → pending")
        broadcast(:task_restored, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [{^task_id, %{status: status}}] ->
        {:reply, {:error, {:not_deleted, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:reassign, task_id, new_agent}, _from, state) do
    # Allow reassign on any non-running status. For completed/failed/rejected,
    # also reset to :pending so it can be re-executed by the new agent.
    rerunnable = [:completed, :failed, :rejected, :paused]

    case :ets.lookup(state.table, task_id) do
      [{^task_id, %{status: :in_progress}}] ->
        {:reply, {:error, {:cannot_reassign, :in_progress}}, state}

      [{^task_id, task}] ->
        old_agent = task.assigned_to
        new_status = if task.status in rerunnable, do: :pending, else: task.status
        updated = %{task | assigned_to: new_agent, status: new_status, result: nil, updated_at: DateTime.utc_now()}
        :ets.insert(state.table, {task_id, updated})
        Logger.info("[TaskBoard] Task #{task_id} reassigned: #{old_agent} → #{new_agent} (status: #{task.status} → #{new_status})")
        broadcast(:task_reassigned, updated)
        {:reply, {:ok, updated}, schedule_save(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get, task_id}, _from, state) do
    case :ets.lookup(state.table, task_id) do
      [{^task_id, task}] -> {:reply, {:ok, task}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, filters}, _from, state) do
    include_deleted = filters[:include_deleted] == true
    filters = Map.delete(filters, :include_deleted)

    tasks =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, task} -> task end)
      |> then(fn tasks ->
        if include_deleted, do: tasks, else: Enum.reject(tasks, &(&1.status == :deleted))
      end)
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:reply, tasks, state}
  end

  def handle_call({:goal_ancestry, task_id}, _from, state) do
    ancestry = build_ancestry(state.table, task_id, [])
    {:reply, ancestry, state}
  end

  @impl true
  def handle_info(:persist, state) do
    save_tasks(state.table)
    {:noreply, %{state | save_timer: nil}}
  end

  # --- Persistence ---

  defp schedule_save(%{save_timer: old_timer} = state) do
    if old_timer, do: Process.cancel_timer(old_timer)
    timer = Process.send_after(self(), :persist, @save_debounce)
    %{state | save_timer: timer}
  end

  defp save_tasks(table) do
    tasks = :ets.tab2list(table) |> Enum.map(fn {_id, task} -> serialize_for_disk(task) end)

    # Group tasks by company and save separately
    grouped = Enum.group_by(tasks, fn t -> t["company"] || "_global" end)

    Enum.each(grouped, fn {company, company_tasks} ->
      Store.save("tasks:#{company}", company_tasks)
    end)

    # Also save a legacy flat list for backward compat
    Store.save("tasks", tasks)
    Logger.debug("[TaskBoard] #{length(tasks)} task(s) saved to disk (#{map_size(grouped)} project(s))")
  end

  defp load_tasks(table) do
    # Load from per-company task keys
    task_keys = Store.list_keys("tasks:")
    # Also check legacy "tasks" key
    all_keys = if task_keys == [], do: ["tasks"], else: task_keys

    counter =
      Enum.reduce(all_keys, 0, fn key, max_counter ->
        case Store.load(key) do
          {:ok, tasks} when is_list(tasks) ->
            loaded =
              tasks
              |> Enum.map(fn t ->
                task = deserialize_from_disk(t)

                # Reset in_progress → pending (interrupted during shutdown)
                task =
                  if task.status == :in_progress do
                    Logger.info("[TaskBoard] Restoring task #{task.id} from :in_progress → :pending")
                    %{task | status: :pending}
                  else
                    task
                  end

                # Don't insert duplicates (in case both legacy and per-company exist)
                unless :ets.member(table, task.id) do
                  :ets.insert(table, {task.id, task})
                end

                case Regex.run(~r/task_(\d+)/, task.id) do
                  [_, n] -> String.to_integer(n)
                  _ -> 0
                end
              end)
              |> Enum.max(fn -> 0 end)

            max(max_counter, loaded)

          _ ->
            max_counter
        end
      end)

    # Migrate legacy "tasks" key if per-company keys were loaded
    if task_keys != [] do
      Store.delete("tasks")
    end

    counter
  end

  defp serialize_for_disk(task) do
    %{
      "id" => task.id,
      "title" => task.title,
      "description" => task.description,
      "status" => to_string(task.status),
      "assigned_to" => task.assigned_to,
      "created_by" => task.created_by,
      "parent_task_id" => task.parent_task_id,
      "depends_on" => Map.get(task, :depends_on),
      "company" => Map.get(task, :company),
      "result" => serialize_result(task.result),
      "retry_count" => Map.get(task, :retry_count, 0),
      "max_retries" => Map.get(task, :max_retries, 2),
      "last_error" => serialize_result(Map.get(task, :last_error)),
      "created_at" => to_string(task.created_at),
      "updated_at" => to_string(task.updated_at),
      "deleted_at" => if(Map.get(task, :deleted_at), do: to_string(task.deleted_at), else: nil)
    }
  end

  defp serialize_result(nil), do: nil
  defp serialize_result({:error, reason}), do: %{"error" => inspect(reason)}
  defp serialize_result(result) when is_binary(result), do: result
  defp serialize_result(result), do: inspect(result, limit: 500)

  defp deserialize_from_disk(t) do
    %{
      id: t["id"],
      title: t["title"],
      description: t["description"],
      status: safe_status_atom(t["status"]),
      assigned_to: t["assigned_to"],
      created_by: t["created_by"],
      parent_task_id: t["parent_task_id"],
      depends_on: t["depends_on"],
      company: t["company"],
      result: t["result"],
      retry_count: t["retry_count"] || 0,
      max_retries: t["max_retries"] || 2,
      last_error: t["last_error"],
      created_at: parse_datetime(t["created_at"]),
      updated_at: parse_datetime(t["updated_at"]),
      deleted_at: parse_datetime_or_nil(t["deleted_at"])
    }
  end

  defp parse_datetime_or_nil(nil), do: nil
  defp parse_datetime_or_nil(str), do: parse_datetime(str)

  @valid_statuses ~w(pending in_progress completed failed awaiting_approval paused rejected deleted)
  defp safe_status_atom(str) when str in @valid_statuses, do: String.to_atom(str)
  defp safe_status_atom(_), do: :pending

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # --- Helpers ---

  defp apply_filters(tasks, filters) do
    Enum.reduce(filters, tasks, fn
      {:status, status}, acc -> Enum.filter(acc, &(&1.status == status))
      {:assigned_to, name}, acc -> Enum.filter(acc, &(&1.assigned_to == name))
      {:created_by, name}, acc -> Enum.filter(acc, &(&1.created_by == name))
      {:company, name}, acc -> Enum.filter(acc, &(Map.get(&1, :company) == name))
      _, acc -> acc
    end)
  end

  defp build_ancestry(_table, nil, acc), do: acc

  defp build_ancestry(table, task_id, acc) do
    case :ets.lookup(table, task_id) do
      [{^task_id, task}] ->
        build_ancestry(table, task.parent_task_id, [%{id: task.id, title: task.title} | acc])

      [] ->
        acc
    end
  end

  defp broadcast(event, task) do
    Shazam.API.EventBus.broadcast(%{
      event: to_string(event),
      task: %{
        id: task.id,
        title: task.title,
        status: task.status,
        assigned_to: task.assigned_to,
        created_by: task.created_by
      }
    })
  end
end

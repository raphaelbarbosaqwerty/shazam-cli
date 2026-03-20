defmodule Shazam.TaskBoard.Persistence do
  @moduledoc """
  Pure utility module for TaskBoard persistence operations.
  Handles loading, saving, serialization, and deserialization of tasks to/from disk.
  """

  require Logger

  alias Shazam.Store

  @valid_statuses ~w(pending in_progress completed failed awaiting_approval paused rejected deleted)

  @doc "Loads tasks from disk into the given ETS table. Returns the max counter value."
  def load_tasks(table) do
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

  @doc "Saves all tasks from the ETS table to disk."
  def save_tasks(table) do
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

  @doc "Serializes a task map (with atom keys) into a string-keyed map for disk storage."
  def serialize_for_disk(task) do
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

  @doc "Deserializes a string-keyed map from disk into a task map with atom keys."
  def deserialize_from_disk(t) do
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

  @doc "Safely converts a status string to an atom, defaulting to :pending."
  def safe_status_atom(str) when str in @valid_statuses, do: String.to_atom(str)
  def safe_status_atom(_), do: :pending

  @doc "Parses an ISO 8601 datetime string, falling back to DateTime.utc_now()."
  def parse_datetime(nil), do: DateTime.utc_now()
  def parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  @doc "Parses an ISO 8601 datetime string or returns nil if input is nil."
  def parse_datetime_or_nil(nil), do: nil
  def parse_datetime_or_nil(str), do: parse_datetime(str)

  # --- Private helpers ---

  defp serialize_result(nil), do: nil
  defp serialize_result({:error, reason}), do: %{"error" => inspect(reason)}
  defp serialize_result(result) when is_binary(result), do: result
  defp serialize_result(result), do: inspect(result, limit: 500)
end

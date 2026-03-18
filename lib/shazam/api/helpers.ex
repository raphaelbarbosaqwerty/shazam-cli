defmodule Shazam.API.Helpers do
  @moduledoc "Shared helpers used across all API sub-routers."

  import Plug.Conn

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  def serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      assigned_to: task.assigned_to,
      created_by: task.created_by,
      parent_task_id: task.parent_task_id,
      depends_on: Map.get(task, :depends_on),
      company: Map.get(task, :company),
      result: serialize_result(task.result),
      created_at: to_string(task.created_at),
      updated_at: to_string(task.updated_at),
      deleted_at: if(Map.get(task, :deleted_at), do: to_string(task.deleted_at), else: nil)
    }
  end

  def serialize_result(nil), do: nil
  def serialize_result({:error, reason}), do: %{error: inspect(reason)}
  def serialize_result(result) when is_binary(result), do: result
  def serialize_result(result), do: inspect(result, limit: 500)

  def find_first_company do
    case Registry.select(Shazam.RalphLoopRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}]) do
      [name | _] -> name
      [] -> nil
    end
  end

  def find_company_for_task(task_id) do
    case Shazam.TaskBoard.get(task_id) do
      {:ok, task} -> Map.get(task, :company)
      _ -> find_first_company()
    end
  end

  def execute_bulk_action("pause", task_id) do
    company = find_company_for_task(task_id)
    if company, do: Shazam.RalphLoop.pause_task(company, task_id), else: Shazam.TaskBoard.pause(task_id)
  end
  def execute_bulk_action("resume", task_id) do
    company = find_company_for_task(task_id)
    if company, do: Shazam.RalphLoop.resume_task(company, task_id), else: Shazam.TaskBoard.resume_task(task_id)
  end
  def execute_bulk_action("delete", task_id), do: Shazam.TaskBoard.delete(task_id)
  def execute_bulk_action("approve", task_id), do: Shazam.TaskBoard.approve(task_id)
  def execute_bulk_action("retry", task_id), do: Shazam.TaskBoard.retry(task_id)
  def execute_bulk_action(action, _task_id), do: {:error, "unknown_action: #{action}"}

  def add_workspace_to_history(path, company \\ nil) do
    history = case Shazam.Store.load("workspace_history") do
      {:ok, %{"workspaces" => list}} -> list
      _ -> []
    end

    existing = Enum.find(history, fn ws -> ws["path"] == path end)
    existing_company = if existing, do: existing["company"], else: nil
    final_company = company || existing_company

    filtered = Enum.reject(history, fn ws -> ws["path"] == path end)

    entry = %{
      "path" => path,
      "name" => Path.basename(path),
      "company" => final_company,
      "added_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    updated = [entry | filtered] |> Enum.take(20)
    Shazam.Store.save("workspace_history", %{"workspaces" => updated})
  end

  def update_workspace_company(path, company_name) do
    history = case Shazam.Store.load("workspace_history") do
      {:ok, %{"workspaces" => list}} -> list
      _ -> []
    end

    updated = Enum.map(history, fn ws ->
      if ws["path"] == path do
        Map.put(ws, "company", company_name)
      else
        ws
      end
    end)

    Shazam.Store.save("workspace_history", %{"workspaces" => updated})
  end
end

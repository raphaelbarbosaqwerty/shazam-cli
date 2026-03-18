defmodule Shazam.API.Routes.TaskRoutes do
  @moduledoc "Handles all /api/tasks/* endpoints."

  use Plug.Router

  import Shazam.API.Helpers

  plug :match
  plug :dispatch

  get "/" do
    filters =
      conn.query_params
      |> Enum.reduce(%{}, fn
        {"status", v}, acc -> Map.put(acc, :status, String.to_existing_atom(v))
        {"assigned_to", v}, acc -> Map.put(acc, :assigned_to, v)
        {"company", v}, acc -> Map.put(acc, :company, v)
        _, acc -> acc
      end)

    tasks = Shazam.tasks(filters) |> Enum.map(&serialize_task/1)
    json(conn, 200, %{tasks: tasks})
  end

  get "/deleted" do
    tasks = Shazam.TaskBoard.list(%{status: :deleted, include_deleted: true})
    json(conn, 200, %{tasks: Enum.map(tasks, &serialize_task/1)})
  end

  post "/bulk" do
    %{"action" => action, "task_ids" => task_ids} = conn.body_params

    results =
      Enum.reduce(task_ids, %{ok: [], errors: %{}}, fn task_id, acc ->
        case execute_bulk_action(action, task_id) do
          :ok ->
            %{acc | ok: acc.ok ++ [task_id]}

          {:ok, _} ->
            %{acc | ok: acc.ok ++ [task_id]}

          {:error, reason} ->
            %{acc | errors: Map.put(acc.errors, task_id, inspect(reason))}
        end
      end)

    Shazam.API.EventBus.broadcast(%{
      event: "bulk_action",
      action: action,
      ok: results.ok,
      errors: results.errors
    })

    json(conn, 200, results)
  end

  post "/pause-all" do
    company = conn.body_params["company"] || find_first_company()
    killed_ids = if company do
      {:ok, ids} = Shazam.RalphLoop.pause_all(company)
      ids
    else
      []
    end

    pending = Shazam.TaskBoard.list(%{status: :pending})
    paused_pending = Enum.reduce(pending, 0, fn task, acc ->
      case Shazam.TaskBoard.fail(task.id, "Paused by user") do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)

    total = length(killed_ids) + paused_pending
    json(conn, 200, %{status: "ok", paused: total, running_killed: length(killed_ids), pending_paused: paused_pending})
  end

  post "/resume-all" do
    tasks = Shazam.TaskBoard.list(%{status: :failed})
    resumed = Enum.reduce(tasks, 0, fn task, acc ->
      if task.result == "Paused by user" do
        case Shazam.TaskBoard.retry(task.id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      else
        acc
      end
    end)

    Shazam.API.EventBus.broadcast(%{event: "tasks_resumed", count: resumed})
    json(conn, 200, %{status: "ok", resumed: resumed})
  end

  get "/:task_id/ancestry" do
    ancestry = Shazam.TaskBoard.goal_ancestry(task_id)
    json(conn, 200, %{ancestry: ancestry})
  end

  post "/:task_id/approve" do
    case Shazam.TaskBoard.approve(task_id) do
      {:ok, task} ->
        Shazam.API.EventBus.broadcast(%{event: "task_approved", task: serialize_task(task)})
        json(conn, 200, serialize_task(task))

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/:task_id/reject" do
    reason = (conn.body_params["reason"] || "Rejected by user")

    case Shazam.TaskBoard.reject(task_id, reason) do
      {:ok, task} ->
        Shazam.API.EventBus.broadcast(%{event: "task_rejected", task: serialize_task(task)})
        json(conn, 200, serialize_task(task))

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/:task_id/retry" do
    case Shazam.TaskBoard.retry(task_id) do
      {:ok, task} ->
        Shazam.API.EventBus.broadcast(%{event: "task_retried", task: serialize_task(task)})
        json(conn, 200, serialize_task(task))

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/:task_id/pause" do
    company = find_company_for_task(task_id)
    if company do
      case Shazam.RalphLoop.pause_task(company, task_id) do
        {:ok, _} -> json(conn, 200, %{status: "paused", task_id: task_id})
        {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
      end
    else
      case Shazam.TaskBoard.pause(task_id) do
        {:ok, _} -> json(conn, 200, %{status: "paused", task_id: task_id})
        {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
      end
    end
  end

  post "/:task_id/resume" do
    company = find_company_for_task(task_id)
    if company do
      case Shazam.RalphLoop.resume_task(company, task_id) do
        {:ok, _} -> json(conn, 200, %{status: "resumed", task_id: task_id})
        {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
      end
    else
      case Shazam.TaskBoard.resume_task(task_id) do
        {:ok, _} -> json(conn, 200, %{status: "resumed", task_id: task_id})
        {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
      end
    end
  end

  post "/:task_id/reassign" do
    new_agent = conn.body_params["assigned_to"] || ""

    if new_agent == "" do
      json(conn, 400, %{error: "assigned_to is required"})
    else
      case Shazam.TaskBoard.reassign(task_id, new_agent) do
        {:ok, task} ->
          json(conn, 200, %{status: "reassigned", task: serialize_task(task)})

        {:error, reason} ->
          json(conn, 422, %{error: inspect(reason)})
      end
    end
  end

  post "/:task_id/restore" do
    case Shazam.TaskBoard.restore(task_id) do
      {:ok, _} ->
        Shazam.API.EventBus.broadcast(%{event: "task_restored", task_id: task_id})
        json(conn, 200, %{status: "restored"})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  delete "/:task_id" do
    case Shazam.TaskBoard.delete(task_id) do
      :ok ->
        Shazam.API.EventBus.broadcast(%{event: "task_deleted", task_id: task_id})
        json(conn, 200, %{status: "deleted"})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  match _ do
    json(conn, 404, %{error: "Not found"})
  end
end

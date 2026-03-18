defmodule Shazam.API.Routes.RalphRoutes do
  @moduledoc "Handles all /api/ralph-loop/* endpoints."

  use Plug.Router

  import Shazam.API.Helpers

  plug :match
  plug :dispatch

  get "/" do
    company = conn.query_params["company"] || find_first_company()
    if company do
      info = Shazam.RalphLoop.status(company)
      json(conn, 200, info)
    else
      json(conn, 200, %{status: :idle, paused: true, company: nil, running_count: 0, running_tasks: [], config: %{}})
    end
  end

  put "/concurrency" do
    %{"max_concurrent" => n} = conn.body_params
    company = conn.body_params["company"] || find_first_company()
    if company, do: Shazam.RalphLoop.set_max_concurrent(company, n)
    json(conn, 200, %{status: "ok", max_concurrent: n})
  end

  post "/kill/:task_id" do
    company = conn.body_params["company"] || find_company_for_task(task_id)
    if company do
      case Shazam.RalphLoop.kill_task(company, task_id) do
        {:ok, _} -> json(conn, 200, %{status: "killed", task_id: task_id})
        {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
      end
    else
      json(conn, 404, %{error: "No company found for task"})
    end
  end

  post "/kill-all" do
    company = conn.body_params["company"] || find_first_company()
    if company do
      {:ok, killed} = Shazam.RalphLoop.pause_all(company)
      json(conn, 200, %{status: "ok", killed: killed})
    else
      json(conn, 200, %{status: "ok", killed: []})
    end
  end

  post "/pause" do
    company = conn.body_params["company"] || conn.query_params["company"] || find_first_company()
    if company, do: Shazam.RalphLoop.pause(company)
    json(conn, 200, %{status: "paused"})
  end

  post "/resume" do
    company = conn.body_params["company"] || conn.query_params["company"] || find_first_company()
    if company, do: Shazam.RalphLoop.resume(company)
    json(conn, 200, %{status: "resumed"})
  end

  put "/config" do
    key = conn.body_params["key"]
    value = conn.body_params["value"]
    company = conn.body_params["company"] || find_first_company()

    if company do
      case Shazam.RalphLoop.set_config(company, key, value) do
        :ok ->
          json(conn, 200, %{status: "ok", key: key, value: value})
        {:error, :invalid_config} ->
          json(conn, 422, %{error: "Invalid config: key=#{key}, value=#{inspect(value)}"})
      end
    else
      json(conn, 404, %{error: "No active company"})
    end
  end

  match _ do
    json(conn, 404, %{error: "Not found"})
  end
end

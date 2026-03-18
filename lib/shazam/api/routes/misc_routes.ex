defmodule Shazam.API.Routes.MiscRoutes do
  @moduledoc "Handles sessions, metrics, agent inbox, health, presets, and templates. Forwarded with prefix /api stripped."

  use Plug.Router

  import Shazam.API.Helpers

  plug :match
  plug :dispatch

  # --- Sessions ---

  get "/sessions" do
    sessions = Shazam.SessionPool.list()
    json(conn, 200, %{sessions: sessions})
  end

  post "/sessions/kill-all" do
    {:ok, count} = Shazam.SessionPool.kill_all()
    json(conn, 200, %{status: "ok", killed: count})
  end

  delete "/sessions/:agent_name" do
    Shazam.SessionPool.kill(agent_name)
    json(conn, 200, %{status: "killed", agent: agent_name})
  end

  # --- Metrics ---

  get "/metrics" do
    metrics = Shazam.Metrics.get_all()
    json(conn, 200, metrics)
  end

  get "/metrics/:agent_name" do
    case Shazam.Metrics.get_agent(agent_name) do
      nil -> json(conn, 404, %{error: "No metrics for agent '#{agent_name}'"})
      metrics -> json(conn, 200, %{agent: agent_name, metrics: metrics})
    end
  end

  # --- Task Templates ---

  get "/task-templates" do
    json(conn, 200, %{templates: Shazam.TaskTemplates.list()})
  end

  # --- Agent Presets ---

  get "/agent-presets" do
    presets = Shazam.AgentPresets.list()
    json(conn, 200, %{presets: presets})
  end

  # --- Health ---

  get "/health" do
    workspace = Application.get_env(:shazam, :workspace, nil)
    json(conn, 200, %{status: "ok", version: "0.1.0", workspace: workspace})
  end

  # --- Legacy Memory Banks ---

  get "/memory-banks" do
    banks = Shazam.SkillMemory.list_all()
      |> Enum.filter(fn s -> String.starts_with?(s.path, "agents/") end)
      |> Enum.map(fn s -> %{agent: s.name, content: s.content, path: s.path} end)
    json(conn, 200, %{banks: banks})
  end

  get "/memory-banks/:agent_name" do
    content = Shazam.SkillMemory.read_agent(agent_name)
    json(conn, 200, %{agent: agent_name, content: content})
  end

  put "/memory-banks/:agent_name" do
    %{"content" => content} = conn.body_params
    case Shazam.SkillMemory.write_agent(agent_name, content) do
      :ok -> json(conn, 200, %{status: "ok"})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/memory-banks/init" do
    case Shazam.SkillMemory.init() do
      {:ok, dir} -> json(conn, 200, %{status: "ok", directory: dir})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  # --- Agent Inbox ---

  post "/agents/:agent_name/message" do
    message = conn.body_params["message"] || ""

    if message == "" do
      json(conn, 400, %{error: "message is required"})
    else
      Shazam.AgentInbox.push(agent_name, message)

      Shazam.API.EventBus.broadcast(%{
        event: "agent_output",
        agent: agent_name,
        type: "user_input",
        content: message
      })

      company = conn.body_params["company"] || find_first_company()
      running_tasks = if company do
        try do
          ralph_status = Shazam.RalphLoop.status(company)
          ralph_status[:running_tasks] || []
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      else
        []
      end
      agent_busy = Enum.any?(running_tasks, fn t ->
        t[:agent] == agent_name
      end)

      if agent_busy do
        json(conn, 202, %{status: "queued", message: "Agent is busy — message queued for after current task"})
      else
        spawn(fn -> Shazam.AgentInbox.execute_pending(agent_name) end)
        json(conn, 200, %{status: "executing", message: "Executing message on agent session"})
      end
    end
  end

  # --- Workspaces list ---

  get "/workspaces" do
    history = case Shazam.Store.load("workspace_history") do
      {:ok, %{"workspaces" => list}} -> list
      _ -> []
    end

    current = Application.get_env(:shazam, :workspace, nil)

    workspaces = Enum.map(history, fn ws ->
      company = ws["company"]
      company_active = if company, do: Shazam.RalphLoop.exists?(company), else: false

      ws
      |> Map.put("active", ws["path"] == current)
      |> Map.put("company_active", company_active)
    end)

    json(conn, 200, %{workspaces: workspaces})
  end

  delete "/workspaces" do
    path = conn.body_params["path"]

    history = case Shazam.Store.load("workspace_history") do
      {:ok, %{"workspaces" => list}} -> list
      _ -> []
    end

    updated = Enum.reject(history, fn ws -> ws["path"] == path end)
    Shazam.Store.save("workspace_history", %{"workspaces" => updated})
    json(conn, 200, %{status: "ok"})
  end

  match _ do
    json(conn, 404, %{error: "Not found"})
  end
end

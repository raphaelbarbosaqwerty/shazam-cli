defmodule Shazam.API.Router do
  @moduledoc """
  REST API for Shazam.

  This is the main entry-point router. It handles CORS, JSON parsing, error
  handling, the WebSocket upgrade, and forwards every API prefix to a
  dedicated sub-router:

    * `/api/companies`   -> `Shazam.API.Routes.CompanyRoutes`
    * `/api/tasks`       -> `Shazam.API.Routes.TaskRoutes`
    * `/api/ralph-loop`  -> `Shazam.API.Routes.RalphRoutes`
    * `/api/workspace`   -> `Shazam.API.Routes.WorkspaceRoutes`
    * `/api/skills`      -> `Shazam.API.Routes.SkillRoutes`
    * `/api/*` (rest)    -> `Shazam.API.Routes.MiscRoutes`
  """

  use Plug.Router
  use Plug.ErrorHandler

  plug CORSPlug, origin: ["*"]
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{error: inspect(reason, limit: 200)}))
  end

  # --- WebSocket upgrade (must stay in main router) ---

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Shazam.API.WebSocket, [], timeout: :infinity)
    |> halt()
  end

  # --- Forwarded sub-routers ---

  forward "/api/companies",  to: Shazam.API.Routes.CompanyRoutes
  forward "/api/tasks",      to: Shazam.API.Routes.TaskRoutes
  forward "/api/ralph-loop", to: Shazam.API.Routes.RalphRoutes
  forward "/api/workspace",  to: Shazam.API.Routes.WorkspaceRoutes
  forward "/api/skills",     to: Shazam.API.Routes.SkillRoutes

  # Sessions, metrics, memory-banks, workspaces list, health, presets,
  # templates, and agent inbox all live under /api with varied sub-paths.
  forward "/api",            to: Shazam.API.Routes.MiscRoutes

  # --- Fallback ---

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end
end

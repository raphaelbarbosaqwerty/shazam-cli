defmodule Shazam.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Initialize persistence directory
    Shazam.Store.init()

    children = [
      # Registries
      {Registry, keys: :unique, name: Shazam.CompanyRegistry},
      {Registry, keys: :unique, name: Shazam.RalphLoopRegistry},

      # Dynamic supervisors
      {DynamicSupervisor, name: Shazam.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Shazam.CompanySupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Shazam.RalphLoopSupervisor, strategy: :one_for_one},

      # Global Task Board (restores tasks from disk)
      Shazam.TaskBoard,

      # Session pool — reuses Claude sessions across tasks
      Shazam.SessionPool,

      # Event Bus for WebSocket
      Shazam.API.EventBus,

      # Metrics tracking (in-memory, ETS-backed)
      Shazam.Metrics,

      # Agent Inbox — user message queue for terminal input
      Shazam.AgentInbox,

      # Agent activity sparkline tracking
      Shazam.AgentPulse,

      # Context persistence — cross-provider context continuity
      Shazam.ContextManager,

      # Circuit Breaker — auto-pauses on consecutive failures
      Shazam.CircuitBreaker,

      # Plugin Manager — loads .shazam/plugins/*.ex at runtime
      Shazam.PluginManager,

      # HTTP API on configurable port
      {Bandit, plug: Shazam.API.Router, port: Application.get_env(:shazam, :port, 4040), thousand_island_options: [num_acceptors: 10]}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Shazam.Supervisor)

    # Restore saved state — but only workspace, NOT companies
    # Companies are started by /start command to avoid race conditions with RalphLoop
    case result do
      {:ok, _pid} ->
        restore_workspace()
        result

      other ->
        other
    end
  end

  defp restore_workspace do
    # Only restore workspace path, NOT companies (they're started by /start)
    case Shazam.Store.load("workspace") do
      {:ok, %{"path" => path}} when is_binary(path) ->
        if File.dir?(path) do
          Application.put_env(:shazam, :workspace, path)
          Logger.info("[Boot] Workspace restored: #{path}")
        end

      _ ->
        :ok
    end

    # Companies are NOT restored here — the /start command handles it
    # This prevents race conditions where restored companies create paused RalphLoops
    # that override the resumed one from /start
  end
end

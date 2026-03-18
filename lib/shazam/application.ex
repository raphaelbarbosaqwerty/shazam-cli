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

      # HTTP API on port 4040
      {Bandit, plug: Shazam.API.Router, port: Application.get_env(:shazam, :port, 4040), thousand_island_options: [num_acceptors: 10]}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Shazam.Supervisor)

    # Restore saved state after the supervision tree is up
    case result do
      {:ok, _pid} ->
        restore_saved_state()
        result

      other ->
        other
    end
  end

  defp restore_saved_state do
    # Restore workspace
    case Shazam.Store.load("workspace") do
      {:ok, %{"path" => path}} when is_binary(path) ->
        if File.dir?(path) do
          Application.put_env(:shazam, :workspace, path)
          Logger.info("[Boot] Workspace restored: #{path}")
        end

      _ ->
        :ok
    end

    # Restore ALL companies (multi-project support)
    company_keys = Shazam.Store.list_keys("company:")

    # Also check legacy single "company" key for migration
    company_keys = case Shazam.Store.load("company") do
      {:ok, %{"name" => _}} -> ["company" | company_keys]
      _ -> company_keys
    end

    Enum.each(company_keys, fn key ->
      case Shazam.Store.load(key) do
        {:ok, %{"name" => name, "mission" => mission, "agents" => agents_raw} = saved} ->
          agents =
            Enum.map(agents_raw, fn a ->
              %{
                name: a["name"],
                role: a["role"],
                supervisor: a["supervisor"],
                domain: a["domain"],
                budget: a["budget"] || 100_000,
                heartbeat_interval: a["heartbeat_interval"] || 60_000,
                tools: a["tools"] || [],
                skills: a["skills"] || [],
                modules: a["modules"] || [],
                system_prompt: a["system_prompt"],
                model: a["model"],
                fallback_model: a["fallback_model"]
              }
            end)

          domain_config = saved["domain_config"] || %{}

          case Shazam.Company.start(%{name: name, mission: mission, agents: agents, domain_config: domain_config}) do
            {:ok, _pid} ->
              Logger.info("[Boot] Company '#{name}' restored with #{length(agents)} agent(s)")

              # Migrate legacy key → namespaced key
              if key == "company" do
                Shazam.Store.save("company:#{name}", saved)
                Shazam.Store.delete("company")
                Logger.info("[Boot] Migrated legacy 'company' key → 'company:#{name}'")
              end

            {:error, reason} ->
              Logger.warning("[Boot] Failed to restore company '#{name}': #{inspect(reason)}")
          end

        _ ->
          :ok
      end
    end)
  end
end

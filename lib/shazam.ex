defmodule Shazam do
  @moduledoc """
  Claude agent orchestrator with support for autonomous companies.

  ## Usage modes

  ### 1. Direct execution (parallel/pipeline)

      Shazam.run([
        %{name: "researcher", prompt: "Research about..."},
        %{name: "writer", prompt: "Write about..."}
      ])

  ### 2. Autonomous company (heartbeat + hierarchy + tasks)

      Shazam.start_company(%{
        name: "ContentTeam",
        mission: "Generate financial content",
        agents: [
          %{name: "manager", role: "Manager", supervisor: nil, budget: 50_000},
          %{name: "researcher", role: "Researcher", supervisor: "manager", budget: 30_000},
          %{name: "writer", role: "Writer", supervisor: "manager", budget: 30_000}
        ]
      })

      Shazam.assign("ContentTeam", "Write article about passive income")
  """

  alias Shazam.{Orchestrator, Company, TaskBoard}

  # --- Direct execution ---

  @doc """
  Executes multiple agents in parallel and returns aggregated results.

  ## Options

    * `:timeout` - Timeout in ms for each agent (default: 300_000 / 5 min)
    * `:max_concurrency` - Maximum simultaneous agents (default: number of schedulers)
    * `:stream` - If `true`, prints output in real time (default: false)
  """
  def run(agents, opts \\ []) do
    Orchestrator.run(agents, opts)
  end

  @doc "Executes agents in parallel with streaming."
  def run_stream(agents, opts \\ []) do
    Orchestrator.run(agents, Keyword.put(opts, :stream, true))
  end

  @doc "Executes a sequential pipeline of agents."
  def pipeline(agents, opts \\ []) do
    Orchestrator.pipeline(agents, opts)
  end

  # --- Autonomous company ---

  @doc "Starts a company with agents, hierarchy, and heartbeats."
  def start_company(config) do
    Company.start(config)
  end

  @doc "Stops a company and all its agents."
  def stop_company(name) do
    Company.stop(name)
  end

  @doc "Creates a task in the company (assigns to the top of the hierarchy by default)."
  def assign(company_name, title, opts \\ []) do
    Company.create_task(company_name, %{
      title: title,
      description: opts[:description],
      assigned_to: opts[:to],
      depends_on: opts[:depends_on]
    })
  end

  @doc "Returns the status of all agents in a company."
  def statuses(company_name) do
    Company.agent_statuses(company_name)
  end

  @doc "Returns the org chart of a company."
  def org_chart(company_name) do
    Company.org_chart(company_name)
  end

  @doc "Returns information about a company."
  def company_info(company_name) do
    Company.info(company_name)
  end

  # --- Tasks ---

  @doc "Lists all tasks."
  def tasks(filters \\ %{}) do
    TaskBoard.list(filters)
  end

end

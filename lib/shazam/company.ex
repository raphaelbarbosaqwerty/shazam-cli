defmodule Shazam.Company do
  @moduledoc """
  Defines and manages a "company" of agents.
  Maintains the org chart, mission, and coordinates the agent lifecycle.
  """

  use GenServer
  require Logger

  alias Shazam.Store
  alias Shazam.Hierarchy

  defstruct [
    :name,
    :mission,
    agents: [],
    status: :stopped,
    # Per-domain config: %{"Desenvolvimento" => %{"allowed_paths" => ["src/", "lib/"]}, ...}
    domain_config: %{}
  ]

  # --- Public API ---

  @doc """
  Starts a company with hierarchically organized agents.

  ## Example

      Shazam.Company.start(%{
        name: "ContentTeam",
        mission: "Generate quality financial content",
        agents: [
          %{name: "manager", role: "Content Manager",
            supervisor: nil, budget: 50_000,
            heartbeat_interval: :timer.minutes(5)},
          %{name: "researcher", role: "Financial Researcher",
            supervisor: "manager", budget: 30_000,
            tools: ["WebSearch", "WebFetch"]},
          %{name: "writer", role: "Article Writer",
            supervisor: "manager", budget: 30_000}
        ]
      })
  """
  def start(config) do
    child_spec = %{
      id: {__MODULE__, config.name},
      start: {GenServer, :start_link, [__MODULE__, config, [name: via(config.name)]]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Shazam.CompanySupervisor, child_spec)
  end

  @doc "Stops the company and all agents."
  @call_timeout :timer.minutes(10)

  def stop(company_name) do
    GenServer.call(via(company_name), :stop, @call_timeout)
  end

  @doc "Returns company information."
  def info(company_name) do
    GenServer.call(via(company_name), :info, @call_timeout)
  end

  @doc "Returns the list of configured agents."
  def get_agents(company_name) do
    GenServer.call(via(company_name), :get_agents, @call_timeout)
  end

  @doc "Creates a task and assigns it to the specified agent (or to the top of the hierarchy)."
  def create_task(company_name, attrs) do
    GenServer.call(via(company_name), {:create_task, attrs}, @call_timeout)
  end

  @doc "Returns the status of all agents."
  def agent_statuses(company_name) do
    GenServer.call(via(company_name), :agent_statuses, @call_timeout)
  end

  @doc "Updates the complete list of agents in the company."
  def update_agents(company_name, agents_raw) do
    GenServer.call(via(company_name), {:update_agents, agents_raw}, @call_timeout)
  end

  @doc "Returns the full agent data (including tools, skills, modules)."
  def get_agents_full(company_name) do
    GenServer.call(via(company_name), :get_agents_full, @call_timeout)
  end

  @doc "Returns the formatted org chart."
  def org_chart(company_name) do
    GenServer.call(via(company_name), :org_chart, @call_timeout)
  end

  @doc "Gets domain config map."
  def get_domain_config(company_name) do
    GenServer.call(via(company_name), :get_domain_config, @call_timeout)
  end

  @doc "Sets allowed_paths for a domain. Pass nil or [] to clear restrictions."
  def set_domain_paths(company_name, domain, paths) do
    GenServer.call(via(company_name), {:set_domain_paths, domain, paths}, @call_timeout)
  end

  # --- Callbacks ---

  @impl true
  def init(config) do
    agents = build_agent_configs(config)

    case Hierarchy.validate_no_cycles(agents) do
      :ok ->
        state = %__MODULE__{
          name: config.name,
          mission: config.mission,
          agents: agents,
          domain_config: config[:domain_config] || %{}
        }

        # Attach to RalphLoop after init returns
        send(self(), :attach_ralph_loop)

        # Persist company config
        save_company(config)

        Logger.info("[Company:#{state.name}] Company started | Mission: #{state.mission}")
        Logger.info("[Company:#{state.name}] Registered agents: #{Enum.map_join(state.agents, ", ", & &1.name)}")
        {:ok, %{state | status: :running}}

      {:error, {:cycle_detected, names}} ->
        {:stop, {:cycle_detected, names}}
    end
  end

  @impl true
  def handle_info(:attach_ralph_loop, state) do
    # Start a dedicated RalphLoop for this company
    child_spec = %{
      id: {Shazam.RalphLoop, state.name},
      start: {Shazam.RalphLoop, :start_link, [state.name, [max_concurrent: 4]]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(Shazam.RalphLoopSupervisor, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Logger.error("[Company:#{state.name}] Failed to start RalphLoop: #{inspect(reason)}")
    end

    Logger.info("[Company:#{state.name}] RalphLoop started")

    # Auto-create memory bank onboarding task if no memory banks exist yet
    send(self(), :maybe_onboard_memory)
    {:noreply, state}
  end

  def handle_info(:maybe_onboard_memory, state) do
    workspace = Application.get_env(:shazam, :workspace, nil)

    # Skip onboarding if workspace is empty (only .shazam dir or nothing)
    if workspace && not project_has_files?(workspace) do
      Logger.debug("[Company:#{state.name}] Empty project — skipping onboarding")
      {:noreply, state}
    else
      banks = Shazam.SkillMemory.list_all()

      # Check if onboarding task already exists (any status)
      existing_tasks = try do
        Shazam.TaskBoard.list(%{company: state.name})
      rescue
        _ -> []
      end

      has_onboarding = Enum.any?(existing_tasks, fn t ->
        title = t.title || ""
        String.contains?(title, "Project Onboarding") or
          String.contains?(title, "Memory Bank") or
          String.contains?(title, "Skill Memory")
      end)

      if not has_onboarding and (banks == [] or length(banks) <= 1) do
        pm = find_top_agent(state.agents)
        if pm do
          Shazam.SkillMemory.init()
          onboarding_prompt = Shazam.SkillMemory.build_onboarding_prompt(state.agents)

          Shazam.TaskBoard.create(%{
            title: "Project Onboarding — Create Memory Banks",
            description: onboarding_prompt,
            assigned_to: pm,
            created_by: "system",
            company: state.name
          })

          Logger.info("[Company:#{state.name}] Memory bank onboarding task created for #{pm}")
        end
      else
        if has_onboarding do
          Logger.debug("[Company:#{state.name}] Onboarding task already exists, skipping")
        else
          Logger.debug("[Company:#{state.name}] Memory banks already populated (#{length(banks)} files)")
        end
      end

      {:noreply, state}
    end
  end

  defp project_has_files?(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn name ->
          name in [".shazam", ".clawster", ".git", ".DS_Store"] or
            String.starts_with?(name, ".")
        end)
        |> Enum.any?()
      {:error, _} -> false
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      mission: state.mission,
      status: state.status,
      agent_count: length(state.agents),
      agents: Enum.map(state.agents, &%{name: &1.name, role: &1.role, supervisor: &1.supervisor})
    }

    {:reply, info, state}
  end

  def handle_call(:get_agents, _from, state) do
    {:reply, state.agents, state}
  end

  def handle_call(:get_agents_full, _from, state) do
    agents_data =
      Enum.map(state.agents, fn a ->
        %{
          name: a.name,
          role: a.role,
          supervisor: a.supervisor,
          domain: a.domain,
          budget: a.budget,
          heartbeat_interval: a.heartbeat_interval,
          tools: a.tools,
          skills: a.skills,
          modules: a.modules,
          system_prompt: a.system_prompt,
          model: a.model,
          fallback_model: a.fallback_model
        }
      end)

    {:reply, agents_data, state}
  end

  def handle_call({:update_agents, agents_raw}, _from, state) do
    new_agents =
      Enum.map(agents_raw, fn a ->
        %Shazam.AgentWorker{
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
          fallback_model: a["fallback_model"],
          company_ref: state.name
        }
      end)

    case Hierarchy.validate_no_cycles(new_agents) do
      :ok ->
        new_state = %{state | agents: new_agents}

        # Re-persist
        save_company_state(new_state)

        Logger.info("[Company:#{state.name}] Agents updated: #{Enum.map_join(new_agents, ", ", & &1.name)}")
        {:reply, :ok, new_state}

      {:error, {:cycle_detected, names}} ->
        Logger.warning("[Company:#{state.name}] Cycle detected in agent hierarchy: #{inspect(names)}")
        {:reply, {:error, {:cycle_detected, names}}, state}
    end
  end

  def handle_call({:create_task, attrs}, _from, state) do
    # If assigned_to was not specified, assign to the top of the hierarchy
    assigned_to = attrs[:assigned_to] || find_top_agent(state.agents)

    result =
      Shazam.TaskBoard.create(
        Map.merge(attrs, %{
          assigned_to: assigned_to,
          description: "Mission: #{state.mission}\n\n#{attrs[:description] || ""}",
          depends_on: attrs[:depends_on],
          company: state.name
        })
      )

    {:reply, result, state}
  end

  def handle_call(:agent_statuses, _from, state) do
    # NOTE: Do NOT call RalphLoop.status() here — it causes a deadlock when
    # RalphLoop is simultaneously calling Company.get_agents() during task completion.
    # The router merges running status from a separate RalphLoop.status() call.

    # Fetch all tasks once for counting per-agent stats
    all_tasks =
      try do
        Shazam.TaskBoard.list(%{})
      rescue
        _ -> []
      end

    statuses =
      Enum.map(state.agents, fn agent ->
        # Per-agent metrics from the database (tokens, duration, success/failure)
        metrics =
          try do
            Shazam.Repo.get_metrics(agent.name)
          rescue
            _ -> %{total: 0, successes: 0, failures: 0, total_tokens: 0}
          end

        # Count tasks by status for this agent
        agent_tasks = Enum.filter(all_tasks, fn t -> t.assigned_to == agent.name end)
        completed = Enum.count(agent_tasks, fn t -> t.status == :completed end)
        failed = Enum.count(agent_tasks, fn t -> t.status == :failed end)
        in_progress = Enum.count(agent_tasks, fn t -> t.status in [:running, :in_progress] end)
        pending = Enum.count(agent_tasks, fn t -> t.status == :pending end)

        tokens_used = metrics.total_tokens || 0
        remaining = max(agent.budget - tokens_used, 0)

        %{
          name: agent.name,
          role: agent.role,
          supervisor: agent.supervisor,
          domain: agent.domain,
          status: :idle,
          budget: agent.budget,
          tokens_used: tokens_used,
          remaining_budget: remaining,
          tasks_completed: completed,
          tasks_failed: failed,
          tasks_in_progress: in_progress,
          tasks_pending: pending,
          tasks_total: length(agent_tasks),
          tools: agent.tools,
          skills: length(agent.skills || []),
          modules: length(agent.modules || [])
        }
      end)

    {:reply, statuses, state}
  end

  def handle_call(:org_chart, _from, state) do
    chart = build_org_chart(state.agents)
    {:reply, chart, state}
  end

  def handle_call(:get_domain_config, _from, state) do
    {:reply, state.domain_config, state}
  end

  def handle_call({:set_domain_paths, domain, paths}, _from, state) do
    new_config = if paths == nil or paths == [] do
      Map.delete(state.domain_config, domain)
    else
      Map.put(state.domain_config, domain, %{"allowed_paths" => paths})
    end

    new_state = %{state | domain_config: new_config}
    save_company_state(new_state)
    Logger.info("[Company:#{state.name}] Domain '#{domain}' paths set to: #{inspect(paths)}")
    {:reply, :ok, new_state}
  end

  def handle_call(:stop, _from, state) do
    Logger.info("[Company:#{state.name}] Shutting down company...")
    Shazam.RalphLoop.stop(state.name)
    Store.delete("company:#{state.name}")
    # Also clean up legacy key if it exists
    Store.delete("company")
    {:stop, :normal, :ok, %{state | status: :stopped}}
  end

  # --- Helpers ---

  defp build_agent_configs(config) do
    Enum.map(config.agents, fn agent ->
      %Shazam.AgentWorker{
        name: agent.name,
        role: agent.role,
        supervisor: agent[:supervisor],
        domain: agent[:domain],
        budget: agent[:budget] || 100_000,
        heartbeat_interval: agent[:heartbeat_interval] || 60_000,
        tools: agent[:tools] || [],
        skills: agent[:skills] || [],
        modules: agent[:modules] || [],
        system_prompt: agent[:system_prompt],
        model: agent[:model],
        fallback_model: agent[:fallback_model],
        company_ref: config.name
      }
    end)
  end

  defp save_company(config) do
    data = %{
      "name" => config.name,
      "mission" => config.mission,
      "agents" => Enum.map(config.agents, fn a ->
        %{
          "name" => a.name || a[:name],
          "role" => a.role || a[:role],
          "supervisor" => a[:supervisor],
          "domain" => a[:domain],
          "budget" => a[:budget] || 100_000,
          "heartbeat_interval" => a[:heartbeat_interval] || 60_000,
          "tools" => a[:tools] || [],
          "skills" => a[:skills] || [],
          "modules" => a[:modules] || [],
          "system_prompt" => a[:system_prompt],
          "model" => a[:model],
          "fallback_model" => a[:fallback_model]
        }
      end)
    }

    Store.save("company:#{config.name}", data)
  end

  defp save_company_state(state) do
    data = %{
      "name" => state.name,
      "mission" => state.mission,
      "agents" => Enum.map(state.agents, fn a ->
        %{
          "name" => a.name,
          "role" => a.role,
          "supervisor" => a.supervisor,
          "domain" => a.domain,
          "budget" => a.budget,
          "heartbeat_interval" => a.heartbeat_interval,
          "tools" => a.tools,
          "skills" => a.skills,
          "modules" => a.modules,
          "system_prompt" => a.system_prompt,
          "model" => a.model,
          "fallback_model" => a.fallback_model
        }
      end),
      "domain_config" => state.domain_config
    }

    Store.save("company:#{state.name}", data)
  end

  defp find_top_agent(agents) do
    case Enum.find(agents, &is_nil(&1.supervisor)) do
      nil -> (hd(agents)).name
      agent -> agent.name
    end
  end

  defp build_org_chart(agents) do
    top = Enum.filter(agents, &is_nil(&1.supervisor))

    Enum.map(top, fn agent ->
      build_tree(agents, agent)
    end)
  end

  defp build_tree(agents, agent) do
    subordinates =
      agents
      |> Enum.filter(&(&1.supervisor == agent.name))
      |> Enum.map(&build_tree(agents, &1))

    %{
      name: agent.name,
      role: agent.role,
      domain: agent.domain,
      budget: agent.budget,
      modules: agent.modules || [],
      subordinates: subordinates
    }
  end

  defp via(name), do: {:via, Registry, {Shazam.CompanyRegistry, name}}
end

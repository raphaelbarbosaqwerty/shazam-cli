defmodule Shazam.TaskScheduler do
  @moduledoc """
  Task selection and scheduling logic extracted from RalphLoop.
  Handles picking tasks, peer reassignment, module locking, and dependency checks.
  """

  require Logger

  alias Shazam.TaskBoard

  @doc """
  Pick tasks for execution. If the assigned agent is busy, try to reassign to an idle peer.
  Module locking: an agent is blocked only if a LOCKED module is owned by an agent
  OUTSIDE their hierarchy (supervisor chain). Agents in the same chain share module access.

  `config` is a map with keys: :company_name, :module_lock, :peer_reassign, :running
  Returns updated running map additions as a list of {task, effective_agent} pairs,
  or directly updates state when given the full state and execute_fn.
  """
  def pick_tasks([], state, _locked, _slots, _execute_fn), do: state
  def pick_tasks(_candidates, state, _locked, 0, _execute_fn), do: state
  def pick_tasks([task | rest], state, locked, slots, execute_fn) do
    busy_agents = state.running |> Enum.map(fn {_id, info} -> info.agent_name end) |> MapSet.new()

    # If the assigned agent is busy, try to find an idle peer (if enabled)
    effective_agent = if MapSet.member?(busy_agents, task.assigned_to) do
      if state.peer_reassign do
        case find_idle_peer(state.company_name, task.assigned_to, busy_agents) do
          nil ->
            Logger.debug("[RalphLoop] ⏳ Task #{task.id}: #{task.assigned_to} busy, no idle peers — waiting")
            nil
          peer ->
            Logger.info("[RalphLoop] ↔ Task #{task.id}: #{task.assigned_to} busy → reassigning to idle peer '#{peer.name}'")
            peer.name
        end
      else
        Logger.debug("[RalphLoop] ⏳ Task #{task.id}: #{task.assigned_to} busy, peer_reassign disabled — waiting")
        nil
      end
    else
      task.assigned_to
    end

    # Skip if no agent available
    if effective_agent == nil do
      pick_tasks(rest, state, locked, slots, execute_fn)
    else
      # Module conflict check (only when module_lock is enabled and there are locked paths)
      {has_conflict, agent_modules} = if state.module_lock and map_size(locked) > 0 do
        agent_profile = resolve_agent_profile(state.company_name, effective_agent)
        mods = if agent_profile, do: extract_module_paths(agent_profile.modules), else: []
        my_hierarchy = hierarchy_agents(state.company_name, effective_agent)

        conflicts =
          mods
          |> Enum.filter(fn path ->
            case Map.get(locked, path) do
              nil -> false
              locking_agent -> not MapSet.member?(my_hierarchy, locking_agent)
            end
          end)

        if conflicts != [] do
          Logger.debug("[RalphLoop] ⏳ Task #{task.id} (#{effective_agent}) waiting — modules locked by agents outside hierarchy: #{inspect(conflicts)}")
          {true, mods}
        else
          {false, mods}
        end
      else
        {false, []}
      end

      if has_conflict do
        pick_tasks(rest, state, locked, slots, execute_fn)
      else
        # Reassign the task in TaskBoard if agent changed
        task_to_run = if effective_agent != task.assigned_to do
          TaskBoard.reassign(task.id, effective_agent)
          %{task | assigned_to: effective_agent}
        else
          task
        end

        new_state = execute_fn.(state, task_to_run)

        if map_size(new_state.running) > map_size(state.running) do
          # Add this agent's modules to locked map
          new_locked = Enum.reduce(agent_modules, locked, fn path, acc ->
            Map.put_new(acc, path, effective_agent)
          end)
          pick_tasks(rest, new_state, new_locked, slots - 1, execute_fn)
        else
          pick_tasks(rest, new_state, locked, slots, execute_fn)
        end
      end
    end
  end

  @doc "Find an idle peer agent that can take the task."
  def find_idle_peer(company_name, original_agent_name, busy_agents) do
    try do
      agents = Shazam.Company.get_agents(company_name)
      original = Enum.find(agents, &(&1.name == original_agent_name))

      unless original do
        nil
      else
        original_role_lower = String.downcase(original.role || "")
        original_domain = original.domain

        # All non-PM, non-original, non-busy agents
        available =
          agents
          |> Enum.filter(fn a ->
            a.name != original_agent_name and
              not MapSet.member?(busy_agents, a.name) and
              not is_pm?(agents, a.name)
          end)

        if available == [] do
          nil
        else
          # 1. Same domain + same role
          same_domain_role = Enum.find(available, fn a ->
            a.domain == original_domain and a.domain != nil and
              String.downcase(a.role || "") == original_role_lower
          end)

          # 2. Same domain, any role
          same_domain = same_domain_role || Enum.find(available, fn a ->
            a.domain == original_domain and a.domain != nil
          end)

          # 3. Same supervisor (legacy hierarchy peer)
          same_supervisor = same_domain || Enum.find(available, fn a ->
            a.supervisor == original.supervisor
          end)

          same_supervisor
        end
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  @doc "Checks if a task is blocked by its dependency."
  def task_blocked?(%{depends_on: nil}), do: false
  def task_blocked?(%{depends_on: ""}), do: false
  def task_blocked?(%{depends_on: []}), do: false
  def task_blocked?(%{depends_on: deps}) when is_list(deps) do
    # Multiple dependencies — blocked if ANY dependency is not completed
    Enum.any?(deps, fn dep ->
      task_blocked?(%{depends_on: dep})
    end)
  end
  def task_blocked?(%{depends_on: dep}) when is_binary(dep) do
    # dep can be a task_id ("task_43") or a task title (from PM output)
    if String.starts_with?(dep, "task_") do
      # Direct ID reference
      case TaskBoard.get(dep) do
        {:ok, %{status: :completed}} -> false
        _ -> true
      end
    else
      # Title reference — search all tasks for a matching title
      all_tasks = TaskBoard.list(%{})
      case Enum.find(all_tasks, fn t -> t.title == dep end) do
        %{status: :completed} -> false
        %{status: s} when s in [:pending, :running, :awaiting_approval] -> true
        nil -> false  # dependency not found — don't block forever
        _ -> true
      end
    end
  end
  def task_blocked?(_), do: false

  @doc "Returns a map of %{module_path => agent_name} for currently running agents."
  def locked_module_paths(running, company_name) do
    running
    |> Enum.flat_map(fn {_task_id, info} ->
      case resolve_agent_profile(company_name, info.agent_name) do
        nil -> []
        profile ->
          extract_module_paths(profile.modules)
          |> Enum.map(fn path -> {path, info.agent_name} end)
      end
    end)
    |> Map.new()
  end

  @doc "Build the set of agents in the same hierarchy (supervisor chain)."
  def hierarchy_agents(company_name, agent_name) do
    try do
      agents = Shazam.Company.get_agents(company_name)
      agent = Enum.find(agents, &(&1.name == agent_name))
      if agent == nil, do: throw(:not_found)

      # Collect: the agent itself + all ancestors (supervisor chain up) + all descendants (reports down)
      ancestors = collect_ancestors(agents, agent_name, MapSet.new([agent_name]))
      descendants = collect_descendants(agents, agent_name, MapSet.new())

      MapSet.union(ancestors, descendants)
    catch
      _, _ -> MapSet.new([agent_name])
    end
  end

  @doc "Walk up the supervisor chain."
  def collect_ancestors(_agents, nil, acc), do: acc
  def collect_ancestors(agents, agent_name, acc) do
    case Enum.find(agents, &(&1.name == agent_name)) do
      nil -> acc
      agent ->
        sup = agent.supervisor
        if sup && !MapSet.member?(acc, sup) do
          collect_ancestors(agents, sup, MapSet.put(acc, sup))
        else
          acc
        end
    end
  end

  @doc "Walk down — find all agents who report to this agent (directly or transitively)."
  def collect_descendants(agents, agent_name, acc) do
    directs = Enum.filter(agents, fn a -> a.supervisor == agent_name end)
    Enum.reduce(directs, acc, fn direct, acc2 ->
      if MapSet.member?(acc2, direct.name) do
        acc2
      else
        acc2 = MapSet.put(acc2, direct.name)
        collect_descendants(agents, direct.name, acc2)
      end
    end)
  end

  @doc "Extract module paths from a list of module maps."
  def extract_module_paths(nil), do: []
  def extract_module_paths(modules) do
    Enum.map(modules, fn
      %{"path" => p} -> p
      %{path: p} -> p
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Resolve an agent profile by company and agent name."
  def resolve_agent_profile(company_name, agent_name) do
    try do
      agents = Shazam.Company.get_agents(company_name)
      Enum.find(agents, &(&1.name == agent_name))
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # --- Private helpers ---

  defp is_pm?(agents, agent_name) do
    Shazam.Hierarchy.find_subordinates(agents, agent_name) != []
  end
end

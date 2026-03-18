defmodule Shazam.Hierarchy do
  @moduledoc """
  Lógica de hierarquia organizacional.
  Resolve supervisores, subordinados e cadeia de delegação.
  """

  @doc "Encontra o supervisor de um agente."
  def find_supervisor(agents, agent_name) do
    case Enum.find(agents, &(&1.name == agent_name)) do
      %{supervisor: nil} -> nil
      %{supervisor: sup} -> Enum.find(agents, &(&1.name == sup))
      nil -> nil
    end
  end

  @doc "Encontra os subordinados diretos de um agente."
  def find_subordinates(agents, agent_name) do
    Enum.filter(agents, &(&1.supervisor == agent_name))
  end

  @doc "Verifica se agent_a é superior (direto ou indireto) de agent_b."
  def is_superior?(agents, agent_a, agent_b) do
    case find_supervisor(agents, agent_b) do
      nil -> false
      %{name: ^agent_a} -> true
      %{name: sup_name} -> is_superior?(agents, agent_a, sup_name)
    end
  end

  @doc "Retorna a cadeia hierárquica completa de um agente até o topo."
  def chain_of_command(agents, agent_name, acc \\ []) do
    case find_supervisor(agents, agent_name) do
      nil -> acc
      %{name: sup_name} = sup -> chain_of_command(agents, sup_name, acc ++ [sup])
    end
  end

  @doc """
  Validates that the agent hierarchy forms a DAG (no cycles).
  Uses Kahn's algorithm for topological sort.

  Returns `:ok` if the hierarchy is acyclic, or
  `{:error, {:cycle_detected, [agent_names]}}` if a cycle exists.
  """
  def validate_no_cycles(agents) do
    # Build adjacency: supervisor -> subordinate (edge from supervisor to subordinate)
    names = MapSet.new(agents, & &1.name)

    # in_degree: how many edges point into each node (i.e., each agent has at most 1 supervisor edge)
    # We model edges as supervisor -> subordinate, so in_degree counts how many supervisors point to a node.
    # Actually for cycle detection in the supervisor chain, we want edges from subordinate -> supervisor
    # (the "reports to" direction), since cycles would be in that direction.
    # But Kahn's works on any directed graph. Let's use supervisor -> subordinate edges.

    # Build adjacency list and in-degree map
    adj =
      Enum.reduce(agents, %{}, fn agent, acc ->
        Map.put_new(acc, agent.name, [])
      end)

    {adj, in_degree} =
      Enum.reduce(agents, {adj, Map.new(agents, &{&1.name, 0})}, fn agent, {adj_acc, deg_acc} ->
        case agent.supervisor do
          nil -> {adj_acc, deg_acc}
          sup when is_binary(sup) ->
            if MapSet.member?(names, sup) do
              adj_acc = Map.update(adj_acc, sup, [agent.name], &[agent.name | &1])
              deg_acc = Map.update(deg_acc, agent.name, 1, &(&1 + 1))
              {adj_acc, deg_acc}
            else
              {adj_acc, deg_acc}
            end
          _ -> {adj_acc, deg_acc}
        end
      end)

    # Start with nodes that have in-degree 0
    queue =
      in_degree
      |> Enum.filter(fn {_name, deg} -> deg == 0 end)
      |> Enum.map(&elem(&1, 0))

    {_sorted, remaining} = kahn_loop(queue, adj, in_degree, [], MapSet.new())

    # Nodes still with in_degree > 0 are in cycles
    cycle_nodes =
      remaining
      |> Enum.filter(fn {_name, deg} -> deg > 0 end)
      |> Enum.map(&elem(&1, 0))

    if cycle_nodes == [] do
      :ok
    else
      {:error, {:cycle_detected, Enum.sort(cycle_nodes)}}
    end
  end

  defp kahn_loop([], _adj, in_degree, sorted, _visited), do: {sorted, in_degree}

  defp kahn_loop([node | rest], adj, in_degree, sorted, visited) do
    if MapSet.member?(visited, node) do
      kahn_loop(rest, adj, in_degree, sorted, visited)
    else
      visited = MapSet.put(visited, node)
      neighbors = Map.get(adj, node, [])

      {new_queue, in_degree} =
        Enum.reduce(neighbors, {rest, in_degree}, fn neighbor, {q, deg} ->
          new_deg = Map.update!(deg, neighbor, &(&1 - 1))

          if Map.get(new_deg, neighbor) == 0 do
            {q ++ [neighbor], new_deg}
          else
            {q, new_deg}
          end
        end)

      kahn_loop(new_queue, adj, in_degree, sorted ++ [node], visited)
    end
  end

  @doc """
  Escolhe o melhor subordinado para uma tarefa.
  Usa a role do agente e a descrição da tarefa para fazer match simples.
  """
  def best_subordinate_for(agents, manager_name, task_description) do
    subordinates = find_subordinates(agents, manager_name)

    if subordinates == [] do
      nil
    else
      # Match simples por keywords na role vs descrição da tarefa
      task_words = task_description |> String.downcase() |> String.split(~r/\s+/)

      subordinates
      |> Enum.map(fn agent ->
        role_words = agent.role |> String.downcase() |> String.split(~r/\s+/)
        score = Enum.count(role_words, fn w -> w in task_words end)
        {agent, score}
      end)
      |> Enum.max_by(fn {_agent, score} -> score end)
      |> elem(0)
    end
  end
end

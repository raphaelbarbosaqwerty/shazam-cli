defmodule Shazam.AgentQuery do
  @moduledoc """
  Agent-to-agent knowledge sharing.

  Allows an agent to query another agent's accumulated context without
  creating a task or running the other agent. This is passive — it reads
  from the other agent's topic files and learnings.

  If the answer is not found in stored context, returns a "not found"
  message suggesting to create a task instead.

  ## Usage in prompts

  Agents receive this instruction when other agents exist:

      To ask another agent for information, output:
      AGENT_QUERY: <agent_name> <question>

  The orchestrator intercepts this pattern in the output and injects
  the response before the agent continues.

  ## Limits

  - Max 2 queries per task execution (prevents loops)
  - Only reads stored context (does NOT execute the other agent)
  - Falls back to TF-IDF search if no direct match
  """

  require Logger

  @max_query_budget 1_500

  @doc """
  Query another agent's knowledge.
  Returns a formatted response string.
  """
  def query(target_agent, question) do
    # Search target agent's context files
    agent_dir = agent_context_dir(target_agent)

    if agent_dir == nil or not File.dir?(agent_dir) do
      "Agent '#{target_agent}' has no stored context yet."
    else
      # 1. Check learnings first (most concise)
      learnings = read_learnings(agent_dir)

      # 2. TF-IDF search across target's topic files
      topic_results = search_agent_topics(agent_dir, question)

      # 3. Assemble response
      build_response(target_agent, question, learnings, topic_results)
    end
  end

  @doc """
  Scan agent output for AGENT_QUERY patterns and resolve them.
  Returns {output_with_responses, query_count}.
  """
  def resolve_queries(output, _current_agent, max_queries \\ 2) do
    pattern = ~r/AGENT_QUERY:\s*(\w+)\s+(.+)/

    {resolved, count} =
      Regex.scan(pattern, output)
      |> Enum.take(max_queries)
      |> Enum.reduce({output, 0}, fn [full_match, target, question], {text, n} ->
        response = query(target, String.trim(question))
        replacement = """
        AGENT_QUERY: #{target} #{question}
        --- Response from #{target}'s knowledge ---
        #{response}
        --- End response ---
        """
        {String.replace(text, full_match, replacement, global: false), n + 1}
      end)

    {resolved, count}
  end

  @doc """
  Build the instruction text that tells agents they can query others.
  Only included when other agents exist.
  """
  def build_instruction(agent_name, all_agents) do
    others = all_agents
      |> Enum.map(fn a ->
        name = if is_struct(a), do: a.name, else: a[:name] || a["name"]
        role = if is_struct(a), do: a.role, else: a[:role] || a["role"]
        {to_string(name), to_string(role)}
      end)
      |> Enum.reject(fn {name, _} -> name == to_string(agent_name) end)

    if others == [] do
      ""
    else
      agent_list = Enum.map_join(others, "\n", fn {name, role} ->
        "  - #{name} (#{role})"
      end)

      """

      ## Team Knowledge
      You can query other agents' knowledge (max 2 per task). Output this pattern:
      AGENT_QUERY: <agent_name> <your question>

      Available agents:
      #{agent_list}

      The system will inject their response. Only use this when you need information another agent has discovered.
      """
    end
  end

  # ── Private ───────────────────────────────────────────

  defp read_learnings(agent_dir) do
    path = Path.join(agent_dir, "_learnings.md")
    case File.read(path) do
      {:ok, content} ->
        Regex.scan(~r/^- (.+)$/m, content)
        |> Enum.map(fn [_, l] -> l end)
        |> Enum.uniq_by(&String.downcase/1)
        |> Enum.take(10)
      _ -> []
    end
  end

  defp search_agent_topics(agent_dir, question) do
    files = Path.wildcard(Path.join(agent_dir, "*.md"))
      |> Enum.reject(&String.ends_with?(&1, "index.md"))
      |> Enum.reject(&String.ends_with?(&1, "_learnings.md"))

    if files == [] do
      ""
    else
      query_tokens = tokenize(question)

      files
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            content
            |> String.split(~r/(?=^### \[)/m)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(fn chunk ->
              chunk_tokens = tokenize(chunk)
              overlap = MapSet.intersection(
                MapSet.new(query_tokens),
                MapSet.new(chunk_tokens)
              ) |> MapSet.size()
              {overlap, chunk}
            end)
            |> Enum.reject(fn {score, _} -> score == 0 end)
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {score, _} -> score end, :desc)
      |> Enum.take(3)
      |> Enum.map(fn {_, chunk} -> String.trim(chunk) end)
      |> Enum.join("\n\n")
    end
  end

  defp build_response(target_agent, _question, learnings, topic_results) do
    parts = []

    parts = if learnings != [] do
      items = Enum.map_join(learnings, "\n", &"- #{&1}")
      parts ++ ["Key knowledge from #{target_agent}:\n#{items}"]
    else
      parts
    end

    parts = if topic_results != "" do
      parts ++ ["Relevant context from #{target_agent}:\n#{String.slice(topic_results, 0..800)}"]
    else
      parts
    end

    if parts == [] do
      "No relevant knowledge found in #{target_agent}'s context. Consider creating a task to ask them directly."
    else
      result = Enum.join(parts, "\n\n")
      if String.length(result) > @max_query_budget do
        String.slice(result, 0, @max_query_budget) <> "\n[...truncated]"
      else
        result
      end
    end
  end

  defp agent_context_dir(agent_name) do
    case Application.get_env(:shazam, :workspace) do
      nil -> nil
      ws -> Path.join([ws, ".shazam", "context", "agents", to_string(agent_name)])
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, " ")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end
end

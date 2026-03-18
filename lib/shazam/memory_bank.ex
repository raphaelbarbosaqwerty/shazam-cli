defmodule Shazam.MemoryBank do
  @moduledoc """
  Persistent memory bank for agents.
  Each agent maintains a knowledge file at {workspace}/.shazam/memory/{agent_name}.md
  These files persist across sessions and help agents build context over time.
  """

  require Logger

  @memory_dir ".shazam/memory"
  # ~2000 tokens ≈ 8000 chars — prevents context bloat from growing memory banks
  @max_memory_chars 8_000

  @doc "Returns the memory directory path for the current workspace."
  def memory_dir do
    workspace = Application.get_env(:shazam, :workspace, nil)
    if workspace, do: Path.join(workspace, @memory_dir), else: nil
  end

  @doc "Ensures the memory directory exists."
  def init do
    case memory_dir() do
      nil -> {:error, :no_workspace}
      dir ->
        File.mkdir_p!(dir)
        {:ok, dir}
    end
  end

  @doc "Returns the file path for an agent's memory bank."
  def agent_path(agent_name) do
    case memory_dir() do
      nil -> nil
      dir -> Path.join(dir, "#{agent_name}.md")
    end
  end

  @doc "Reads an agent's memory bank. Returns empty string if not found."
  def read(agent_name) do
    case agent_path(agent_name) do
      nil -> ""
      path ->
        case File.read(path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end
    end
  end

  @doc "Writes content to an agent's memory bank."
  def write(agent_name, content) do
    case agent_path(agent_name) do
      nil -> {:error, :no_workspace}
      path ->
        init()
        File.write(path, content)
    end
  end

  @doc "Lists all memory banks with their content."
  def list_all do
    case memory_dir() do
      nil -> []
      dir ->
        if File.dir?(dir) do
          dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(fn filename ->
            agent_name = String.replace_suffix(filename, ".md", "")
            content = File.read!(Path.join(dir, filename))
            %{agent: agent_name, content: content, path: Path.join(dir, filename)}
          end)
        else
          []
        end
    end
  end

  @doc "Deletes an agent's memory bank."
  def delete(agent_name) do
    case agent_path(agent_name) do
      nil -> {:error, :no_workspace}
      path -> File.rm(path)
    end
  end

  @doc """
  Builds the memory bank prompt section for an agent.
  Accepts `full: false` to skip update instructions (for reused sessions that already have them).
  """
  def build_prompt(agent_name, opts \\ []) do
    full? = Keyword.get(opts, :full, true)
    memory = read(agent_name)
    memory_path = agent_path(agent_name)

    # Truncate memory to avoid context bloat
    truncated_memory = truncate_memory(memory)

    memory_context = if truncated_memory != "" do
      """

      ## Your Memory Bank
      The following is your persistent memory from previous tasks. Use this context to make better decisions:

      #{truncated_memory}
      """
    else
      ""
    end

    # Only include update instructions on full prompts (new sessions).
    # Reused sessions already received these instructions.
    update_instructions = if full? and memory_path do
      """

      ## Memory Bank Update Instructions
      After completing your task, update your memory bank at: `#{memory_path}`
      Structure: Project Overview, Architecture & Patterns, My Responsibilities, Lessons Learned, Dependencies.
      Always READ existing content first, then add/update relevant sections. Keep it concise.
      """
    else
      ""
    end

    memory_context <> update_instructions
  end

  defp truncate_memory(""), do: ""
  defp truncate_memory(memory) when byte_size(memory) <= @max_memory_chars, do: memory
  defp truncate_memory(memory) do
    truncated = String.slice(memory, 0, @max_memory_chars)
    # Cut at last newline to avoid breaking mid-line
    case String.split(truncated, "\n") |> Enum.slice(0..-2//1) |> Enum.join("\n") do
      "" -> truncated
      clean -> clean <> "\n\n[... memory truncated — keep your memory bank concise]"
    end
  end

  @doc """
  Builds a PM prompt for creating initial memory banks for all agents.
  Used when onboarding a new project.
  """
  def build_onboarding_prompt(agents) do
    agent_list =
      agents
      |> Enum.map(fn a ->
        modules = case a.modules do
          nil -> "none"
          [] -> "none"
          mods -> Enum.map_join(mods, ", ", fn m -> m["path"] || m[:path] || "" end)
        end
        "- **#{a.name}** (#{a.role}): modules: #{modules}"
      end)
      |> Enum.join("\n")

    memory_dir = memory_dir()

    """
    ## Project Onboarding Task

    You must analyze the entire project structure and create initial memory banks for each agent.

    ### Agents in the team:
    #{agent_list}

    ### Instructions:
    1. Read the project structure (use Glob and Read tools to explore the codebase thoroughly)
    2. Understand the tech stack, architecture, key patterns, and module organization
    3. For EACH agent listed above, create a memory bank file at `#{memory_dir}/{agent_name}.md`

    Each memory bank should contain:
    - Project overview relevant to that agent's role
    - Architecture patterns they need to know
    - Key files and modules in their responsibility area
    - Dependencies and integrations with other parts of the system
    - Any conventions or patterns they should follow

    Make each memory bank specific to the agent's role and responsibilities. A frontend agent needs different context than a backend agent.

    ### File format for each memory bank:
    ```markdown
    # Memory Bank: {agent_name}
    Last updated: #{Date.utc_today()}

    ## Project Overview
    [Relevant project context for this agent]

    ## Architecture & Patterns
    [Key patterns, tech stack, conventions]

    ## My Responsibilities
    [Modules and areas this agent owns]

    ## Key Files
    [Important files this agent should know about]

    ## Dependencies & Integrations
    [How this agent's work connects to others]
    ```
    """
  end
end

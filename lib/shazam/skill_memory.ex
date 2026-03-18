defmodule Shazam.SkillMemory do
  @moduledoc """
  Skill-graph based memory system for agents.

  Follows the Remotion Skills pattern:
  - `.shazam/memories/SKILL.md` — root index with navigation pointers
  - `.shazam/memories/project/` — project-level knowledge (overview, architecture, conventions)
  - `.shazam/memories/agents/` — per-agent context and responsibilities
  - `.shazam/memories/rules/` — reusable domain rules (testing, git, deploy, etc.)
  - `.shazam/memories/decisions/` — architectural decision records (ADRs)

  Each file uses frontmatter (name, description, tags) and can reference other skills
  via relative paths like `[./rules/testing.md](./rules/testing.md)`.

  Agents receive only relevant skills based on their role, domain, and tags —
  not the entire memory bank. This prevents context pollution.
  """

  require Logger

  @memories_dir "memories"
  @max_skill_chars 4_000
  @max_total_chars 12_000

  # ── Paths ────────────────────────────────────────────────────

  def base_dir do
    workspace = Application.get_env(:shazam, :workspace, nil)
    if workspace, do: Path.join([workspace, ".shazam", @memories_dir]), else: nil
  end

  def skill_path(relative_path) do
    case base_dir() do
      nil -> nil
      dir -> Path.join(dir, relative_path)
    end
  end

  # ── Init ─────────────────────────────────────────────────────

  @doc "Creates the memory directory structure and root SKILL.md."
  def init do
    case base_dir() do
      nil -> {:error, :no_workspace}
      dir ->
        Enum.each(["project", "agents", "rules", "decisions"], fn sub ->
          File.mkdir_p!(Path.join(dir, sub))
        end)

        skill_path = Path.join(dir, "SKILL.md")
        unless File.exists?(skill_path) do
          File.write!(skill_path, default_skill_index())
        end

        {:ok, dir}
    end
  end

  # ── Read / Write ─────────────────────────────────────────────

  @doc "Reads a skill file and returns {frontmatter, content}."
  def read_skill(relative_path) do
    case skill_path(relative_path) do
      nil -> {:error, :no_workspace}
      path ->
        case File.read(path) do
          {:ok, raw} -> {:ok, parse_frontmatter(raw)}
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  @doc "Writes a skill file with frontmatter + content."
  def write_skill(relative_path, frontmatter, content) do
    case skill_path(relative_path) do
      nil -> {:error, :no_workspace}
      path ->
        dir = Path.dirname(path)
        File.mkdir_p!(dir)

        yaml_header = frontmatter
          |> Enum.map(fn {k, v} -> "#{k}: #{format_yaml_value(v)}" end)
          |> Enum.join("\n")

        File.write(path, "---\n#{yaml_header}\n---\n\n#{content}")
    end
  end

  @doc "Lists all skill files recursively."
  def list_all do
    case base_dir() do
      nil -> []
      dir ->
        if File.dir?(dir) do
          dir
          |> list_files_recursive()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(fn path ->
            relative = Path.relative_to(path, dir)
            {:ok, {fm, content}} = read_skill(relative)
            %{
              path: relative,
              name: fm["name"] || Path.rootname(Path.basename(relative)),
              description: fm["description"] || "",
              tags: parse_tags(fm["tags"] || fm["metadata"]),
              content: content,
              size: byte_size(content)
            }
          end)
        else
          []
        end
    end
  end

  # ── Agent Memory (backward compat) ──────────────────────────

  @doc "Reads an agent's dedicated memory file."
  def read_agent(agent_name) do
    case read_skill("agents/#{agent_name}.md") do
      {:ok, {_fm, content}} -> content
      _ -> ""
    end
  end

  @doc "Writes an agent's dedicated memory file."
  def write_agent(agent_name, content) do
    write_skill(
      "agents/#{agent_name}.md",
      %{"name" => agent_name, "description" => "Memory bank for agent #{agent_name}", "tags" => "agent, #{agent_name}"},
      content
    )
  end

  # ── Skill Graph Resolution ──────────────────────────────────

  @doc """
  Resolves which skills an agent should receive based on their profile.

  Selection criteria:
  1. Always: SKILL.md (root index) — truncated to navigation only
  2. Always: agents/{agent_name}.md (agent's own memory)
  3. Always: project/overview.md (project context)
  4. By domain: project/{domain}.md, rules related to domain
  5. By role: role-specific rules (PM gets decisions/, QA gets rules/testing.md, etc.)
  6. By tags: skills matching agent's domain/role tags
  """
  def resolve_for_agent(agent_profile) do
    all_skills = list_all()
    agent_name = agent_profile.name
    role = String.downcase(agent_profile.role || "")
    domain = agent_profile.domain
    agent_tags = build_agent_tags(role, domain)

    # 1. Root index (always, but just navigation pointers)
    root = Enum.find(all_skills, fn s -> s.path == "SKILL.md" end)

    # 2. Agent's own memory (always)
    agent_skill = Enum.find(all_skills, fn s -> s.path == "agents/#{agent_name}.md" end)

    # 3. Project overview (always)
    overview = Enum.find(all_skills, fn s -> s.path == "project/overview.md" end)

    # 4. Domain-specific skills
    domain_skills = if domain do
      Enum.filter(all_skills, fn s ->
        s.path != "SKILL.md" and
        (String.contains?(s.path, domain) or
         Enum.any?(s.tags, fn t -> t == domain end))
      end)
    else
      []
    end

    # 5. Role-specific skills
    role_skills = cond do
      is_pm?(role) ->
        Enum.filter(all_skills, fn s ->
          String.starts_with?(s.path, "decisions/") or
          String.starts_with?(s.path, "project/")
        end)
      is_qa?(role) ->
        Enum.filter(all_skills, fn s ->
          Enum.any?(s.tags, fn t -> t in ["testing", "qa", "test"] end) or
          String.contains?(s.path, "test")
        end)
      true ->
        Enum.filter(all_skills, fn s ->
          String.starts_with?(s.path, "rules/") and
          Enum.any?(s.tags, fn t -> t in agent_tags end)
        end)
    end

    # 6. Merge, deduplicate, respect budget
    [root, agent_skill, overview]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(domain_skills)
    |> Enum.concat(role_skills)
    |> Enum.uniq_by(& &1.path)
    |> Enum.reject(fn s -> s.path == "SKILL.md" and s == root end) # keep root but process it
    |> then(fn skills ->
      # Re-add root at beginning
      if root, do: [root | Enum.reject(skills, fn s -> s.path == "SKILL.md" end)], else: skills
    end)
    |> budget_skills()
  end

  @doc "Builds the prompt section from resolved skills."
  def build_prompt(agent_profile, opts \\ []) do
    full? = Keyword.get(opts, :full, true)
    skills = resolve_for_agent(agent_profile)

    if skills == [] do
      ""
    else
      skill_sections = skills
        |> Enum.map(fn s ->
          truncated = truncate(s.content, @max_skill_chars)
          """
          ### #{s.name}
          #{truncated}
          """
        end)
        |> Enum.join("\n")

      update_instructions = if full? do
        memory_dir = base_dir()
        """

        ## Skill Memory Update Instructions
        After completing your task, update relevant skill files at: `#{memory_dir}/`
        - Your personal memory: `#{memory_dir}/agents/#{agent_profile.name}.md`
        - Project knowledge: `#{memory_dir}/project/`
        - Domain rules: `#{memory_dir}/rules/`
        - Decisions: `#{memory_dir}/decisions/`

        Each file uses frontmatter:
        ```
        ---
        name: skill-name
        description: One line description
        tags: tag1, tag2
        ---
        Content here. Reference other skills: [./rules/testing.md](./rules/testing.md)
        ```
        Always READ existing content first, then update. Keep files focused and concise.
        """
      else
        ""
      end

      """

      ## Skill Memory
      The following skills were loaded based on your role and domain:

      #{skill_sections}
      #{update_instructions}
      """
    end
  end

  @doc "Builds the onboarding prompt for PMs to create initial skill files."
  def build_onboarding_prompt(agents) do
    agent_list = agents
      |> Enum.map(fn a ->
        modules = case a.modules do
          nil -> "none"
          [] -> "none"
          mods -> Enum.map_join(mods, ", ", fn m -> m["path"] || m[:path] || "" end)
        end
        "- **#{a.name}** (#{a.role}): domain: #{a.domain || "general"}, modules: #{modules}"
      end)
      |> Enum.join("\n")

    memory_dir = base_dir()

    """
    ## Project Onboarding — Create Skill Memory

    Analyze the project and create skill files following this structure:

    ### Required files:

    1. `#{memory_dir}/project/overview.md` — Project overview, tech stack, goals
    2. `#{memory_dir}/project/architecture.md` — Architecture patterns, folder structure, key modules
    3. `#{memory_dir}/project/conventions.md` — Naming conventions, code style, patterns used

    4. For EACH agent, create `#{memory_dir}/agents/{agent_name}.md`:
    #{agent_list}

    5. Create domain rules as needed:
       - `#{memory_dir}/rules/testing.md` — How to test in this project
       - `#{memory_dir}/rules/git-workflow.md` — Branch/commit conventions
       - Any other rules relevant to the project

    ### File format (every file must use this):
    ```markdown
    ---
    name: skill-name
    description: One-line description of what this skill teaches
    tags: relevant, tags, here
    ---

    Content here. Use markdown. Reference other skills with relative paths:
    - For testing details, load [./rules/testing.md](./rules/testing.md)
    - For architecture, see [./project/architecture.md](./project/architecture.md)
    ```

    ### Update SKILL.md index:
    After creating all files, update `#{memory_dir}/SKILL.md` to list all skills with descriptions.

    ### Important:
    - Keep each file focused on ONE topic
    - Use cross-references instead of duplicating knowledge
    - Tags are used to match skills to agents — choose them carefully
    - Agent files should contain role-specific context, not general project knowledge
    """
  end

  # ── Private helpers ──────────────────────────────────────────

  defp default_skill_index do
    """
    ---
    name: skill-index
    description: Root index for project skill memory
    tags: index, navigation
    ---

    ## Project Skills

    Load individual skill files for detailed knowledge:

    ### Project
    - [project/overview.md](project/overview.md) — Project overview, goals, tech stack
    - [project/architecture.md](project/architecture.md) — Architecture patterns, folder structure
    - [project/conventions.md](project/conventions.md) — Code conventions and standards

    ### Rules
    - [rules/testing.md](rules/testing.md) — Testing strategy and patterns
    - [rules/git-workflow.md](rules/git-workflow.md) — Git branch and commit conventions

    ### Decisions
    - Architectural decisions are stored in `decisions/` as individual files

    ### Agents
    - Each agent has a personal memory at `agents/{agent_name}.md`
    """
  end

  defp parse_frontmatter(raw) do
    case String.split(raw, "---", parts: 3) do
      ["", yaml_section, content] ->
        fm = yaml_section
          |> String.trim()
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ":", parts: 2) do
              [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
              _ -> acc
            end
          end)
        {fm, String.trim(content)}
      _ ->
        {%{}, String.trim(raw)}
    end
  end

  defp parse_tags(nil), do: []
  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
  defp parse_tags(tags) when is_map(tags) do
    case tags["tags"] do
      nil -> []
      t -> parse_tags(t)
    end
  end
  defp parse_tags(_), do: []

  defp format_yaml_value(v) when is_binary(v), do: v
  defp format_yaml_value(v), do: inspect(v)

  defp build_agent_tags(role, domain) do
    role_tags = cond do
      is_pm?(role) -> ["management", "planning", "coordination"]
      is_qa?(role) -> ["testing", "qa", "quality"]
      String.contains?(role, "design") -> ["design", "ui", "ux"]
      String.contains?(role, "dev") or String.contains?(role, "engineer") -> ["development", "code", "implementation"]
      true -> ["general"]
    end

    domain_tags = if domain, do: [domain], else: []
    role_tags ++ domain_tags
  end

  defp is_pm?(role), do: String.contains?(role, "manager") or String.contains?(role, " pm")
  defp is_qa?(role), do: String.contains?(role, "qa") or String.contains?(role, "test") or String.contains?(role, "quality")

  defp budget_skills(skills) do
    {selected, _budget} = Enum.reduce(skills, {[], 0}, fn skill, {acc, used} ->
      size = skill.size
      if used + size <= @max_total_chars do
        {acc ++ [skill], used + size}
      else
        # Try truncated version
        truncated_size = min(size, @max_skill_chars)
        if used + truncated_size <= @max_total_chars do
          {acc ++ [%{skill | content: truncate(skill.content, @max_skill_chars)}], used + truncated_size}
        else
          {acc, used}
        end
      end
    end)
    selected
  end

  defp truncate(content, max) when byte_size(content) <= max, do: content
  defp truncate(content, max) do
    sliced = String.slice(content, 0, max)
    case String.split(sliced, "\n") |> Enum.slice(0..-2//1) |> Enum.join("\n") do
      "" -> sliced
      clean -> clean <> "\n\n[... truncated — load full file for details]"
    end
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          if File.dir?(full), do: list_files_recursive(full), else: [full]
        end)
      _ -> []
    end
  end
end

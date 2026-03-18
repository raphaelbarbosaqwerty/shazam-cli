defmodule Shazam.TaskExecutor.PromptBuilder do
  @moduledoc """
  All prompt-building functions extracted from TaskExecutor.
  """

  alias Shazam.TaskBoard

  # Instructions for technical (non-PM) agents — ensure they IMPLEMENT, not just plan
  @implementation_instructions """

  ## CRITICAL: Implementation Rules
  You MUST implement the task, not just plan it. Do NOT output a plan or list of steps without executing them.
  - Read the relevant code, understand it, then make the changes.
  - Write actual code, create/edit files, run tests if applicable.
  - If the task is too large for a single execution, break it into sub-tasks using the JSON format below and they will be delegated automatically:
  ```subtasks
  [{"title": "...", "description": "...", "assigned_to": "YOUR_OWN_NAME_OR_PEER", "depends_on": null}]
  ```
  - Only use subtasks if absolutely necessary. Prefer implementing directly.
  - NEVER respond with just a plan, outline, or proposal. Your output must contain actual implemented changes.
  """

  # Compact PM instructions — static, never changes. ~300 tokens instead of ~800.
  @pm_instructions """

  ## You are a PM/Manager
  Your ONLY job: break the task into sub-tasks and delegate. You do NOT read code, investigate, write code, or use tools. You are a dispatcher.

  Rules: describe expected behavior (not implementation), define acceptance criteria (ACs), do NOT mention file names/classes/functions, do NOT define architecture.

  IMPORTANT: Distribute tasks across ALL available agents. Do NOT assign everything to one agent.
  IMPORTANT: Maximize parallelism. Use "depends_on" ONLY when a task truly cannot start before another finishes. Most tasks can run in parallel — set "depends_on": null for those.

  ## CRITICAL: Test & QA Routing Rules
  - ALL test-related tasks (writing tests, running tests, test plans, E2E, integration, unit tests) MUST be assigned to QA agents ONLY. NEVER assign test tasks to developers.
  - Developers implement features and fix bugs. They do NOT write or run tests.
  - When a QA agent reports a bug or failing test, create a fix task and assign it to the appropriate developer (any team). The fix task must reference the QA findings.
  - After a dev fixes a bug, create a verification task for the QA agent to confirm the fix.
  - Typical flow: PM → QA (test) → PM (bug report) → Dev (fix) → PM → QA (verify fix)

  Output format: one-line summary + JSON block. Nothing else.
  ```subtasks
  [{"title": "...", "description": "...\\n\\nACs:\\n- ...", "assigned_to": "agent_name", "depends_on": null}]
  ```
  Each sub-task needs 2+ ACs. Use exact agent names. "depends_on" is optional — only use when strictly necessary.
  """

  def implementation_instructions, do: @implementation_instructions
  def pm_instructions, do: @pm_instructions

  @doc "Build skills prompt section."
  def build_skills_prompt([]), do: ""
  def build_skills_prompt(nil), do: ""
  def build_skills_prompt(skills) do
    skills_text =
      skills
      |> Enum.map(fn skill ->
        "### #{skill["name"]}\n#{skill["content"]}"
      end)
      |> Enum.join("\n\n")

    "\n\n## Available skills\nUse the following skills when executing tasks:\n\n#{skills_text}"
  end

  @doc "Build modules prompt section."
  def build_modules_prompt([]), do: ""
  def build_modules_prompt(nil), do: ""
  def build_modules_prompt(modules) do
    modules_text =
      modules
      |> Enum.map(fn m ->
        "- **#{m["name"]}**: `#{m["path"]}` — #{m["description"] || "no description"}"
      end)
      |> Enum.join("\n")

    "\n\n## Modules under your responsibility\nYou must focus EXCLUSIVELY on the following project modules. Do not modify files outside these paths:\n\n#{modules_text}"
  end

  @doc "Build PM prompt with subordinate list and cross-team delegation info."
  def build_pm_prompt(agent_profile) do
    try do
      agents = Shazam.Company.get_agents(agent_profile.company_ref)
      subordinates = Shazam.Hierarchy.find_subordinates(agents, agent_profile.name)

      if subordinates != [] do
        agent_list =
          subordinates
          |> Enum.map(fn a ->
            modules_info = case a.modules do
              [] -> ""
              nil -> ""
              mods -> " | Modules: #{Enum.map_join(mods, ", ", fn m -> m["name"] || m[:name] || "" end)}"
            end
            domain_info = if a.domain, do: " [#{a.domain}]", else: ""
            "- #{a.name}: #{a.role}#{domain_info}#{modules_info}"
          end)
          |> Enum.join("\n")

        # Find other PMs/teams for cross-team delegation
        my_subordinate_names = MapSet.new(subordinates, & &1.name)
        other_pms =
          agents
          |> Enum.reject(fn a -> a.name == agent_profile.name end)
          |> Enum.filter(fn a ->
            subs = Shazam.Hierarchy.find_subordinates(agents, a.name)
            subs != [] and not MapSet.member?(my_subordinate_names, a.name)
          end)

        cross_team_section =
          if other_pms != [] do
            other_list =
              other_pms
              |> Enum.map(fn pm ->
                pm_subs = Shazam.Hierarchy.find_subordinates(agents, pm.name)
                sub_roles = pm_subs |> Enum.map(fn s -> "#{s.name} (#{s.role})" end) |> Enum.join(", ")
                domain_info = if pm.domain, do: " [#{pm.domain}]", else: ""
                "- #{pm.name}: #{pm.role}#{domain_info} → manages: #{sub_roles}"
              end)
              |> Enum.join("\n")

            """

            ### Cross-team delegation
            When a task requires work from another team (e.g. analysis findings that need development, bug fixes from QA), you can assign subtasks to these other PMs:
            #{other_list}

            Assign the subtask to the OTHER PM's name — they will break it down for their own team.
            Example: if analysis results need development, assign to the development PM, not directly to a developer.
            """
          else
            ""
          end

        @pm_instructions <> "\n### Your subordinates:\n#{agent_list}\n" <> cross_team_section
      else
        ""
      end
    rescue
      _ -> ""
    catch
      :exit, _ -> ""
    end
  end

  @doc "Build designer context prompt."
  def build_designer_context(agent_profile) do
    role_lower = String.downcase(agent_profile.role || "")
    is_designer = String.contains?(role_lower, "design")

    if is_designer do
      try do
        agents = Shazam.Company.get_agents(agent_profile.company_ref)
        # Find the PM (agent with subordinates or top of hierarchy)
        pm = Enum.find(agents, fn a ->
          subs = Shazam.Hierarchy.find_subordinates(agents, a.name)
          subs != []
        end)

        pm_name = if pm, do: pm.name, else: "manager"

        # Also list all agents for reference
        agent_list = agents
          |> Enum.reject(&(&1.name == agent_profile.name))
          |> Enum.map(fn a -> "- #{a.name}: #{a.role}" end)
          |> Enum.join("\n")

        """

        ## Team Context
        When creating subtasks, assign them to the PM: **#{pm_name}**
        The PM will then break them down further for the development team.

        ### Available team members:
        #{agent_list}
        """
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end
    else
      ""
    end
  end

  @doc "Build role-specific rules (dev vs QA test boundaries)."
  def build_role_rules(agent_profile) do
    role_lower = String.downcase(agent_profile.role || "")

    is_dev = String.contains?(role_lower, "dev") or
             String.contains?(role_lower, "programmer") or
             String.contains?(role_lower, "programador") or
             String.contains?(role_lower, "engineer") and
             not String.contains?(role_lower, "qa") and
             not String.contains?(role_lower, "test") and
             not String.contains?(role_lower, "devops")

    is_qa = String.contains?(role_lower, "qa") or
            String.contains?(role_lower, "test") or
            String.contains?(role_lower, "quality")

    cond do
      is_dev ->
        """

        ## CRITICAL: Testing Policy
        You are a developer. You do NOT write tests, test files, test cases, or test suites.
        Testing is the exclusive responsibility of QA agents.
        - Do NOT create any test files (*_test.*, *_spec.*, test_*)
        - Do NOT write unit tests, integration tests, E2E tests, or any kind of test
        - Do NOT modify existing test files
        - Focus ONLY on implementing features, fixing bugs, and writing production code
        - If a task asks you to write tests, report in your output that testing must be delegated to QA
        """

      is_qa ->
        try do
          agents = Shazam.Company.get_agents(agent_profile.company_ref)

          # Find the PM this QA reports to
          pm = if agent_profile.supervisor do
            Enum.find(agents, fn a -> a.name == agent_profile.supervisor end)
          end

          pm = pm || Enum.find(agents, fn a ->
            subs = Shazam.Hierarchy.find_subordinates(agents, a.name)
            subs != [] and Enum.any?(subs, fn s -> s.name == agent_profile.name end)
          end)

          pm_name = if pm, do: pm.name, else: "manager"

          """

          ## QA Workflow: Bug Reporting
          You are a QA agent. You write and run tests. When you find bugs or failing tests:

          1. Document the bug clearly: what failed, expected vs actual behavior, steps to reproduce
          2. Create a subtask assigned to your PM (**#{pm_name}**) so the PM can delegate the fix to a developer
          3. The PM will assign the fix to the appropriate dev from any team

          Use this format to report bugs to the PM:
          ```subtasks
          [{"title": "Bug fix: [brief description]", "description": "## Bug Found During Testing\\n\\n**Test**: [test name/description]\\n**Expected**: [expected behavior]\\n**Actual**: [actual behavior]\\n**Steps to Reproduce**:\\n1. ...\\n2. ...\\n\\n**Error/Log**:\\n```\\n[error output]\\n```\\n\\nACs:\\n- Fix the [specific issue]\\n- [expected correct behavior after fix]", "assigned_to": "#{pm_name}", "depends_on": null}]
          ```

          IMPORTANT: Do NOT fix bugs yourself. Report them to the PM so developers can fix them.
          After a developer fixes a bug, you may be asked to verify the fix — run the relevant tests again to confirm.
          """
        rescue
          _ -> ""
        catch
          :exit, _ -> ""
        end

      true ->
        ""
    end
  end

  @doc "Build analyst context prompt — tells analyst agents to send findings to their PM."
  def build_analyst_context(agent_profile) do
    role_lower = String.downcase(agent_profile.role || "")
    is_analyst = String.contains?(role_lower, "analyst") or String.contains?(role_lower, "analista")

    if is_analyst do
      try do
        agents = Shazam.Company.get_agents(agent_profile.company_ref)

        # Find the PM this analyst reports to (supervisor or nearest PM in hierarchy)
        pm = if agent_profile.supervisor do
          Enum.find(agents, fn a -> a.name == agent_profile.supervisor end)
        end

        # If supervisor is not a PM, find the nearest PM up the chain
        pm = pm || Enum.find(agents, fn a ->
          subs = Shazam.Hierarchy.find_subordinates(agents, a.name)
          subs != [] and Enum.any?(subs, fn s -> s.name == agent_profile.name end)
        end)

        pm_name = if pm, do: pm.name, else: "manager"

        # List team members for context
        agent_list = agents
          |> Enum.reject(&(&1.name == agent_profile.name))
          |> Enum.map(fn a -> "- #{a.name}: #{a.role}" end)
          |> Enum.join("\n")

        """

        ## Team Context
        You report to the PM: **#{pm_name}**
        When creating subtasks with your analysis findings, assign them to: **#{pm_name}**
        The PM will then break them down into actionable development tasks for the team.

        IMPORTANT: Replace "PM_NAME" in your subtasks JSON with "#{pm_name}".

        ### Available team members:
        #{agent_list}
        """
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end
    else
      ""
    end
  end

  @doc "Build domain path restriction prompt."
  def build_domain_restriction_prompt(agent_profile, company_name) do
    domain = agent_profile.domain
    if domain == nil or domain == "" or company_name == nil do
      ""
    else
      try do
        domain_config = Shazam.Company.get_domain_config(company_name)
        case Map.get(domain_config, domain) do
          %{"allowed_paths" => paths} when is_list(paths) and paths != [] ->
            """

            ## IMPORTANT: Path Restriction
            Your team (#{domain}) is restricted to the following directories:
            #{Enum.map_join(paths, "\n", fn p -> "- `#{p}`" end)}

            You MUST NOT create, edit, or delete files outside of these directories.
            If a task requires changes outside your allowed paths, report this in your output
            and do NOT proceed with those changes.
            """
          _ ->
            ""
        end
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end
    end
  end

  @doc "Build task prompt based on session type."
  def build_task_prompt(agent_profile, task, :new) do
    ancestry = TaskBoard.goal_ancestry(task.id)
    retry_context = Shazam.RetryPolicy.build_retry_context(task)

    context_parts = [
      "## Your role: #{agent_profile.role}",
      if(ancestry != [],
        do: "## Goal chain:\n#{Enum.map_join(ancestry, "\n", &"- #{&1.title}")}",
        else: nil
      )
    ]

    context_str = context_parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

    """
    #{retry_context}#{context_str}

    ## Task
    #{task.title}

    #{if task.description, do: "## Details\n#{task.description}", else: ""}
    """
  end

  def build_task_prompt(_agent_profile, task, :reused) do
    retry_context = Shazam.RetryPolicy.build_retry_context(task)

    """
    #{retry_context}## New Task
    #{task.title}

    #{if task.description, do: "## Details\n#{task.description}", else: ""}
    """
  end

  @doc "Build tech stack context prompt from stored config."
  def build_tech_stack_prompt do
    tech_stack = Application.get_env(:shazam, :tech_stack, nil)

    if tech_stack && is_map(tech_stack) && map_size(tech_stack) > 0 do
      lines =
        tech_stack
        |> Enum.map(fn {key, value} -> "- **#{key}**: #{value}" end)
        |> Enum.join("\n")

      "\n\n## Project Tech Stack\n#{lines}\n"
    else
      ""
    end
  end
end

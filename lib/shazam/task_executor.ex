defmodule Shazam.TaskExecutor do
  @moduledoc """
  Task execution logic extracted from RalphLoop.
  Handles building prompts, resolving agent profiles, and running agent tasks.
  """

  require Logger

  alias Shazam.{Orchestrator, SkillMemory, Provider.Resolver}
  alias Shazam.TaskExecutor.PromptBuilder

  @task_timeout 1_800_000

  @doc "Run an agent task with the given profile, task, and company name."
  def run_agent_task(agent_profile, task, company_name) do
    # Build session config
    # Load system prompt: config_file > .shazam/agents/<name>.md > hardcoded preset
    base_prompt = load_agent_prompt(agent_profile)
    skills_prompt = PromptBuilder.build_skills_prompt(agent_profile.skills)
    modules_prompt = PromptBuilder.build_modules_prompt(agent_profile.modules)
    memory_prompt = SkillMemory.build_prompt(agent_profile)
    pm_prompt = PromptBuilder.build_pm_prompt(agent_profile)
    designer_prompt = PromptBuilder.build_designer_context(agent_profile)
    analyst_prompt = PromptBuilder.build_analyst_context(agent_profile)
    role_rules_prompt = PromptBuilder.build_role_rules(agent_profile)

    is_pm = pm_prompt != ""
    model = if is_pm and (agent_profile.model == nil or agent_profile.model == "") do
      Logger.info("[RalphLoop] Agent '#{agent_profile.name}' is a PM — using Haiku for speed")
      "claude-haiku-4-5-20251001"
    else
      agent_profile.model
    end

    tools = if is_pm, do: [], else: agent_profile.tools

    domain_restriction_prompt = PromptBuilder.build_domain_restriction_prompt(agent_profile, company_name)
    tech_stack_prompt = PromptBuilder.build_tech_stack_prompt()

    # Non-PM agents get implementation instructions to avoid "plan only" outputs
    impl_prompt = if is_pm, do: "", else: PromptBuilder.implementation_instructions()

    # Agent-to-agent query instruction (if other agents exist)
    agent_query_prompt = try do
      agents = Shazam.Company.get_agents(company_name)
      Shazam.AgentQuery.build_instruction(agent_profile.name, agents)
    catch
      _, _ -> ""
    end

    # Check if agent has a specific workspace (resolve early for prompt)
    agent_workspace = Map.get(agent_profile, :workspace, nil)
    workspace = if agent_workspace do
      workspaces = Application.get_env(:shazam, :workspaces, %{})
      case Map.get(workspaces, agent_workspace) do
        %{path: path} when is_binary(path) -> path
        _ -> Application.get_env(:shazam, :workspace, nil)
      end
    else
      Application.get_env(:shazam, :workspace, nil)
    end
    # Build workspace enforcement prompt
    workspace_prompt = if agent_workspace && workspace do
      """

      ## CRITICAL: Workspace Restriction
      You are working EXCLUSIVELY in this repository: #{workspace}
      Workspace name: #{agent_workspace}

      RULES:
      - ALL files you create, edit, or delete MUST be inside #{workspace}
      - Do NOT create files in any parent directory or sibling repository
      - Do NOT reference or modify files outside your workspace
      - Your current working directory (cwd) is set to #{workspace}
      - Use RELATIVE paths from your workspace root, not absolute paths
      - If a task requires changes outside your workspace, report it and do NOT proceed
      """
    else
      ""
    end

    system_prompt = base_prompt <> impl_prompt <> role_rules_prompt <> tech_stack_prompt <> skills_prompt <> modules_prompt <> memory_prompt <> pm_prompt <> designer_prompt <> analyst_prompt <> domain_restriction_prompt <> agent_query_prompt <> workspace_prompt

    modules = agent_profile.modules || []

    module_dirs =
      if workspace && modules != [] do
        modules
        |> Enum.map(fn m -> Path.join(workspace, m["path"] || m[:path] || "") end)
        |> Enum.filter(&File.dir?/1)
      else
        []
      end

    session_opts =
      [
        system_prompt: system_prompt,
        timeout: @task_timeout,
        permission_mode: :bypass_permissions,
        setting_sources: ["user", "project"],
        env: %{"CLAUDECODE" => ""}
      ]
      |> maybe_add_opt(:allowed_tools, if(tools != [], do: tools ++ ["Skill"], else: nil), tools != [])
      |> maybe_add_opt(:model, model, model != nil)
      |> maybe_add_opt(:cwd, workspace, workspace != nil)
      |> maybe_add_opt(:add_dir, module_dirs, module_dirs != [])

    # Resolve provider — default to ClaudeCode
    provider_mod = Resolver.resolve(agent_profile.provider || Application.get_env(:shazam, :default_provider))

    # Build git context once per task execution
    git_context = Shazam.GitContext.build_context(workspace)

    # Non-session providers (Codex, Cursor, Gemini) bypass SessionPool
    if not provider_mod.supports_sessions?() do
      prompt = PromptBuilder.build_task_prompt(agent_profile, task, :new)

      # Inject cross-provider context (task history, team activity, keyword matches)
      context = Shazam.ContextManager.build_context(agent_profile.name, task)
      prompt = if context != "", do: context <> "\n\n" <> prompt, else: prompt

      # Inject git context before the task prompt
      prompt = if git_context != "", do: git_context <> "\n\n" <> prompt, else: prompt

      prompt = case Shazam.PluginManager.run_pipeline(
        :before_query, {prompt, agent_profile.name}, company_name: company_name
      ) do
        {:ok, {modified_prompt, _}} -> modified_prompt
        _ -> prompt
      end

      Shazam.Metrics.set_status(agent_profile.name, "working")
      Shazam.API.EventBus.broadcast(%{
        event: "agent_output", agent: agent_profile.name,
        text: "Working on: #{String.slice(task.title || "", 0..80)} (#{provider_mod.name()})"
      })

      result = provider_mod.execute(:stateless, prompt,
        agent_name: agent_profile.name,
        system_prompt: system_prompt,
        model: model,
        timeout: @task_timeout,
        cwd: workspace
      )

      # Resolve agent-to-agent queries — if output contains queries,
      # re-execute ONCE with the answers injected into the prompt
      result = case result do
        {:ok, text, files} ->
          {resolved, query_count} = Shazam.AgentQuery.resolve_queries(text, agent_profile.name)
          if query_count > 0 do
            # Re-execute with query answers as context
            followup_prompt = """
            You previously asked #{query_count} question(s) to other agents. Here are their answers:

            #{resolved}

            Now continue with your original task using this information.
            Original task: #{task.title}
            #{if task.description, do: "\nDetails: #{task.description}", else: ""}
            """

            Shazam.API.EventBus.broadcast(%{
              event: "agent_output", agent: agent_profile.name,
              type: "text", content: "Re-executing with #{query_count} query answer(s)..."
            })

            case provider_mod.execute(:stateless, followup_prompt,
              agent_name: agent_profile.name,
              system_prompt: system_prompt,
              model: model,
              timeout: @task_timeout,
              cwd: workspace
            ) do
              {:ok, text2, files2} -> {:ok, text2, Enum.uniq(files ++ files2)}
              other -> other
            end
          else
            {:ok, resolved, files}
          end
        other -> other
      end

      result = case Shazam.PluginManager.run_pipeline(
        :after_query, {result, agent_profile.name}, company_name: company_name
      ) do
        {:ok, {modified, _}} -> modified
        _ -> result
      end

      Shazam.Metrics.set_status(agent_profile.name, "idle")
      result
    else

    # Session-based providers (ClaudeCode) use SessionPool
    case Shazam.SessionPool.checkout(agent_profile.name, session_opts) do
      {:ok, session_pid, session_type} ->
        # Build prompt based on session type:
        # :new → full context (role, ancestry, memory instructions)
        # :reused → lean prompt (just the task — agent already has context)
        prompt = PromptBuilder.build_task_prompt(agent_profile, task, session_type)

        # Inject context for new sessions (reused sessions already have history)
        prompt = if session_type == :new do
          context = Shazam.ContextManager.build_context(agent_profile.name, task)
          prompt = if context != "", do: context <> "\n\n" <> prompt, else: prompt
          # Inject git context before the task prompt
          if git_context != "", do: git_context <> "\n\n" <> prompt, else: prompt
        else
          prompt
        end

        # Plugin hook: before_query (can mutate prompt or halt)
        prompt = case Shazam.PluginManager.run_pipeline(
          :before_query, {prompt, agent_profile.name},
          company_name: company_name
        ) do
          {:ok, {modified_prompt, _agent}} -> modified_prompt
          {:halt, _reason} -> prompt
          _ -> prompt
        end

        Logger.info("[RalphLoop] #{if session_type == :reused, do: "Reusing", else: "New"} session for '#{agent_profile.name}' | prompt ~#{String.length(prompt)} chars")

        Shazam.API.EventBus.broadcast(%{
          event: "agent_output",
          agent: agent_profile.name,
          text: "Working on: #{String.slice(task.title || "", 0..80)}"
        })

        Shazam.Metrics.set_status(agent_profile.name, "working")

        result = Orchestrator.execute_on_session(session_pid, agent_profile.name, prompt)

        # Resolve agent-to-agent queries — re-execute with answers if queries found
        result = case result do
          {:ok, text, files} ->
            {resolved, query_count} = Shazam.AgentQuery.resolve_queries(text, agent_profile.name)
            if query_count > 0 do
              followup = """
              You previously asked #{query_count} question(s) to other agents. Here are their answers:

              #{resolved}

              Now continue with your original task using this information.
              Original task: #{task.title}
              #{if task.description, do: "\nDetails: #{task.description}", else: ""}
              """

              Shazam.API.EventBus.broadcast(%{
                event: "agent_output", agent: agent_profile.name,
                type: "text", content: "Re-executing with #{query_count} query answer(s)..."
              })

              case Orchestrator.execute_on_session(session_pid, agent_profile.name, followup) do
                {:ok, text2, files2} -> {:ok, text2, Enum.uniq(files ++ files2)}
                other -> other
              end
            else
              {:ok, resolved, files}
            end
          other -> other
        end

        # Plugin hook: after_query (can mutate result)
        result = case Shazam.PluginManager.run_pipeline(
          :after_query, {result, agent_profile.name},
          company_name: company_name
        ) do
          {:ok, {modified_result, _agent}} -> modified_result
          _ -> result
        end

        Shazam.Metrics.set_status(agent_profile.name, "idle")

        # Check-in (mark as available for next task)
        Shazam.SessionPool.checkin(agent_profile.name)

        case result do
          {:ok, text, files} -> {:ok, text, files}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[RalphLoop] SessionPool checkout failed for '#{agent_profile.name}': #{inspect(reason)}")

        # Fallback — run via Orchestrator (creates ephemeral session)
        prompt = PromptBuilder.build_task_prompt(agent_profile, task, :new)

        agent_config = %{
          name: agent_profile.name,
          prompt: prompt,
          system_prompt: system_prompt,
          tools: tools,
          model: model,
          fallback_model: agent_profile.fallback_model,
          modules: agent_profile.modules
        }

        case Orchestrator.run([agent_config], timeout: @task_timeout) do
          [%{result: {:ok, result}, touched_files: files}] -> {:ok, result, files}
          [%{result: {:ok, result}}] -> {:ok, result, []}
          [%{result: {:error, reason}}] -> {:error, reason}
          other -> {:error, {:unexpected, other}}
        end
    end
    end # if not provider_mod.supports_sessions?
  end

  # Delegate prompt builders for backward compatibility
  defdelegate build_skills_prompt(skills), to: PromptBuilder
  defdelegate build_modules_prompt(modules), to: PromptBuilder
  defdelegate build_pm_prompt(agent_profile), to: PromptBuilder
  defdelegate build_designer_context(agent_profile), to: PromptBuilder
  defdelegate build_analyst_context(agent_profile), to: PromptBuilder
  defdelegate build_role_rules(agent_profile), to: PromptBuilder
  defdelegate build_domain_restriction_prompt(agent_profile, company_name), to: PromptBuilder
  defdelegate build_task_prompt(agent_profile, task, session_type), to: PromptBuilder
  defdelegate build_tech_stack_prompt(), to: PromptBuilder

  @doc "Conditionally add an option to a keyword list."
  def maybe_add_opt(opts, _key, _value, false), do: opts
  def maybe_add_opt(opts, key, value, true), do: Keyword.put(opts, key, value)

  # Load agent prompt with priority: config_file > .shazam/agents/<name>.md > hardcoded
  defp load_agent_prompt(agent_profile) do
    # 1. Check explicit config_file from YAML
    config_file = Map.get(agent_profile, :config_file)
    if config_file && config_file != "" do
      workspace = Application.get_env(:shazam, :workspace, File.cwd!())
      path = if String.starts_with?(config_file, "/"), do: config_file, else: Path.join(workspace, config_file)
      case Shazam.AgentConfig.read_agent_from_path(path) do
        {:ok, %{system_prompt: prompt}} when prompt != nil and prompt != "" -> prompt
        _ -> load_agent_prompt_by_name(agent_profile)
      end
    else
      load_agent_prompt_by_name(agent_profile)
    end
  end

  # 2. Check .shazam/agents/<name>.md
  defp load_agent_prompt_by_name(agent_profile) do
    case Shazam.AgentConfig.read_agent(agent_profile.name) do
      {:ok, %{system_prompt: prompt}} when prompt != nil and prompt != "" -> prompt
      _ -> agent_profile.system_prompt || "You are #{agent_profile.role}. Be direct and objective."
    end
  end
end

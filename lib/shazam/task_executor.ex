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

    system_prompt = base_prompt <> impl_prompt <> role_rules_prompt <> tech_stack_prompt <> skills_prompt <> modules_prompt <> memory_prompt <> pm_prompt <> designer_prompt <> analyst_prompt <> domain_restriction_prompt

    # Check if agent has a specific workspace
    agent_workspace = Map.get(agent_profile, :workspace, nil)
    workspace = if agent_workspace do
      # Look up in workspaces config
      workspaces = Application.get_env(:shazam, :workspaces, %{})
      case Map.get(workspaces, agent_workspace) do
        %{path: path} when is_binary(path) -> path
        _ -> Application.get_env(:shazam, :workspace, nil)
      end
    else
      Application.get_env(:shazam, :workspace, nil)
    end
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

    # Non-session providers (Codex, Cursor, Gemini) bypass SessionPool
    if not provider_mod.supports_sessions?() do
      prompt = PromptBuilder.build_task_prompt(agent_profile, task, :new)

      # Inject cross-provider context (task history, team activity, keyword matches)
      context = Shazam.ContextManager.build_context(agent_profile.name, task)
      prompt = if context != "", do: context <> "\n\n" <> prompt, else: prompt

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
          if context != "", do: context <> "\n\n" <> prompt, else: prompt
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

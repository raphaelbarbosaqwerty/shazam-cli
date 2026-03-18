defmodule Shazam.TaskExecutor do
  @moduledoc """
  Task execution logic extracted from RalphLoop.
  Handles building prompts, resolving agent profiles, and running agent tasks.
  Backend-agnostic — uses Shazam.Backend.Registry for session management.
  """

  require Logger

  alias Shazam.{Orchestrator, SkillMemory}
  alias Shazam.TaskExecutor.PromptBuilder
  alias Shazam.Backend.{Registry, ToolMapper}

  @task_timeout 1_800_000

  @doc "Run an agent task with the given profile, task, and company name."
  def run_agent_task(agent_profile, task, company_name) do
    backend = Registry.current()

    base_prompt = agent_profile.system_prompt || "You are #{agent_profile.role}. Be direct and objective."
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

    # Map tools to backend-specific names
    raw_tools = if is_pm, do: [], else: agent_profile.tools
    tools = ToolMapper.map_tools(raw_tools, backend)

    domain_restriction_prompt = PromptBuilder.build_domain_restriction_prompt(agent_profile, company_name)
    tech_stack_prompt = PromptBuilder.build_tech_stack_prompt()

    impl_prompt = if is_pm, do: "", else: PromptBuilder.implementation_instructions()

    system_prompt = base_prompt <> impl_prompt <> role_rules_prompt <> tech_stack_prompt <> skills_prompt <> modules_prompt <> memory_prompt <> pm_prompt <> designer_prompt <> analyst_prompt <> domain_restriction_prompt

    workspace = Application.get_env(:shazam, :workspace, nil)
    modules = agent_profile.modules || []

    module_dirs =
      if workspace && modules != [] do
        modules
        |> Enum.map(fn m -> Path.join(workspace, m["path"] || m[:path] || "") end)
        |> Enum.filter(&File.dir?/1)
      else
        []
      end

    # Build backend-agnostic config, then let the backend translate
    config = %{
      system_prompt: system_prompt,
      timeout: @task_timeout,
      cwd: workspace,
      model: model,
      tools: tools,
      module_dirs: module_dirs
    }

    session_opts = backend.build_session_opts(config)

    case Shazam.SessionPool.checkout(agent_profile.name, session_opts) do
      {:ok, session, session_type} ->
        prompt = PromptBuilder.build_task_prompt(agent_profile, task, session_type)

        Logger.info("[RalphLoop] #{if session_type == :reused, do: "Reusing", else: "New"} session for '#{agent_profile.name}' on #{backend.name()} | prompt ~#{String.length(prompt)} chars")

        Shazam.API.EventBus.broadcast(%{
          event: "agent_output",
          agent: agent_profile.name,
          text: "Working on: #{String.slice(task.title || "", 0..80)}"
        })

        Shazam.Metrics.set_status(agent_profile.name, "working")

        result = Orchestrator.execute_on_session(session, agent_profile.name, prompt)

        Shazam.Metrics.set_status(agent_profile.name, "idle")

        Shazam.SessionPool.checkin(agent_profile.name)

        case result do
          {:ok, text, files} -> {:ok, text, files}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[RalphLoop] SessionPool checkout failed for '#{agent_profile.name}': #{inspect(reason)}")

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
end

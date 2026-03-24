defmodule Shazam.CLI.TuiPort.Commands.Tools do
  @moduledoc """
  Tool commands: /plan, /qa, /knowledge, /knowledge --update
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/knowledge --update", state) do
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    Helpers.send_event(state.port, "system", "info", "Updating project memory bank...")

    # Create the memory bank directory structure
    memories_dir = Path.join(workspace, ".shazam/memories")
    File.mkdir_p!(Path.join(memories_dir, "project"))
    File.mkdir_p!(Path.join(memories_dir, "agents"))
    File.mkdir_p!(Path.join(memories_dir, "rules"))

    prompt = """
    Analyze this project's codebase thoroughly and create/update the memory bank files.

    You must READ the actual project files to understand the codebase. Use Read, Grep, and Glob tools.

    Create or update these files in .shazam/memories/:

    1. **project/overview.md** — Project name, purpose, tech stack, main features, directory structure
    2. **project/architecture.md** — Key architectural patterns, module organization, data flow
    3. **project/conventions.md** — Code style, naming conventions, import order, error handling patterns
    4. **rules/testing.md** — Testing framework, test patterns, what to test
    5. **rules/git-workflow.md** — Branch naming, commit message format, PR process
    6. **SKILL.md** — Root index linking to all memory files

    Each file must have YAML frontmatter:
    ```
    ---
    name: file-name
    description: One line description
    tags: tag1, tag2
    ---
    ```

    Be thorough — read package.json/mix.exs for dependencies, look at folder structure,
    read a few source files to understand patterns.
    """

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: "Update project memory bank",
        assigned_to: pm_name,
        created_by: "human",
        company: company_name,
        description: prompt
      })
      Helpers.send_event(state.port, pm_name, "task_created", "Memory bank update task created")
    end

    Status.send_status(state)
    state
  end

  def handle_command("/knowledge", state) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    memories_dir = Path.join(workspace, ".shazam/memories")

    if File.dir?(memories_dir) do
      files = list_memory_files(memories_dir, "")
      if files == [] do
        Helpers.send_event(state.port, "system", "info", "Knowledge bank empty. Run /knowledge --update")
      else
        Helpers.send_event(state.port, "system", "info", "Knowledge bank (.shazam/memories/):")
        Enum.each(files, fn file ->
          Helpers.send_event(state.port, "system", "info", "  #{file}")
        end)
      end
    else
      Helpers.send_event(state.port, "system", "info", "No knowledge bank found. Run /knowledge --update")
    end
    state
  end

  def handle_command("/plan " <> description, state) do
    description = String.trim(description)
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)

    cond do
      description == "--list" ->
        plans = Shazam.PlanManager.list_plans()
        if plans == [] do
          Helpers.send_event(state.port, "system", "info", "No plans found. Create one with /plan <description>")
        else
          Enum.each(plans, fn p ->
            task_count = length(p.tasks)
            Helpers.send_event(state.port, "system", "info", "  #{p.id}: [#{p.status}] #{p.title} (#{task_count} tasks)")
          end)
        end

      String.starts_with?(description, "--approve ") ->
        plan_id = String.trim_leading(description, "--approve ") |> String.trim()
        case Shazam.PlanManager.read_plan(plan_id) do
          {:ok, plan} ->
            case Shazam.PlanManager.create_tasks_from_plan(plan, company_name) do
              {:ok, count} ->
                Helpers.send_event(state.port, "system", "info", "Plan '#{plan.title}' approved — #{count} tasks created (auto-approved)")
              {:error, reason} ->
                Helpers.send_event(state.port, "system", "error", "Failed to create tasks: #{inspect(reason)}")
            end
          {:error, _} ->
            Helpers.send_event(state.port, "system", "error", "Plan #{plan_id} not found")
        end

      String.starts_with?(description, "--show ") ->
        plan_id = String.trim_leading(description, "--show ") |> String.trim()
        case Shazam.PlanManager.read_plan(plan_id) do
          {:ok, plan} ->
            Helpers.send_event(state.port, "system", "info", "Plan: #{plan.title} [#{plan.status}]")
            plan.tasks
            |> Enum.group_by(fn t -> t[:phase] || "Tasks" end)
            |> Enum.each(fn {phase, tasks} ->
              Helpers.send_event(state.port, "system", "info", "  #{phase}:")
              Enum.each(tasks, fn t ->
                dep = if t[:depends_on], do: " (after: #{t.depends_on})", else: ""
                agent = t[:assigned_to] || "unassigned"
                Helpers.send_event(state.port, "system", "info", "    - #{t.title} → #{agent}#{dep}")
              end)
            end)
          {:error, _} ->
            Helpers.send_event(state.port, "system", "error", "Plan #{plan_id} not found")
        end

      true ->
        # Create a new plan
        Helpers.send_event(state.port, pm_name, "info", "Creating plan: #{description}...")

        prompt = Shazam.PlanManager.build_plan_prompt(description)
        plan_id = Shazam.PlanManager.next_id()

        if Code.ensure_loaded?(Shazam.TaskBoard) do
          Shazam.TaskBoard.create(%{
            title: "Create plan: #{description}",
            assigned_to: pm_name,
            created_by: "human",
            company: company_name,
            description: prompt <> "\n\nPlan ID: #{plan_id}\nAfter generating the plan JSON, the system will save it for review."
          })
          Helpers.send_event(state.port, pm_name, "task_created", "Planning task created. Once PM completes, review with /plan --show #{plan_id}")
        end
    end

    Status.send_status(state)
    state
  end

  def handle_command("/qa" <> rest, state) do
    args = String.trim(rest)
    company_name = Helpers.deep_get(state, [:company, :name])

    cond do
      args == "" ->
        # List QA docs
        docs = Shazam.QAManager.list_docs()
        if docs == [] do
          Helpers.send_event(state.port, "system", "info", "No QA docs found. They are auto-generated when dev tasks complete.")
        else
          Enum.each(docs, fn d ->
            icon = cond do
              d.total == 0 -> "○"
              d.checked == d.total -> "✓"
              true -> "…"
            end
            Helpers.send_event(state.port, "system", "info", "  #{icon} #{d.task_id}: #{d.title} (#{d.checked}/#{d.total})")
          end)
        end

      String.starts_with?(args, "--generate ") ->
        task_id = String.trim_leading(args, "--generate ") |> String.trim()
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          case Shazam.TaskBoard.get(task_id) do
            {:ok, task} ->
              case Shazam.QAManager.generate_qa_doc(task) do
                {:ok, path} ->
                  Helpers.send_event(state.port, "system", "info", "QA doc generated: #{Path.basename(path)}")
                _ ->
                  Helpers.send_event(state.port, "system", "error", "Failed to generate QA doc")
              end
            _ ->
              Helpers.send_event(state.port, "system", "error", "Task #{task_id} not found")
          end
        end

      args == "--report" ->
        case Shazam.QAManager.generate_report() do
          {:ok, path} ->
            Helpers.send_event(state.port, "system", "info", "QA report generated: #{Path.basename(path)}")
          _ ->
            Helpers.send_event(state.port, "system", "error", "Failed to generate report")
        end

      args == "--auto on" ->
        Application.put_env(:shazam, :qa_auto, true)
        Helpers.send_event(state.port, "system", "info", "QA auto-generation: ON")
        Helpers.send_event(state.port, "system", "info", "(session only — add `qa_auto: true` to shazam.yaml to persist)")

      args == "--auto off" ->
        Application.put_env(:shazam, :qa_auto, false)
        Helpers.send_event(state.port, "system", "info", "QA auto-generation: OFF")
        Helpers.send_event(state.port, "system", "info", "(session only — add `qa_auto: false` to shazam.yaml to persist)")

      String.starts_with?(args, "--validate ") ->
        task_id = String.trim_leading(args, "--validate ") |> String.trim()
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          case Shazam.TaskBoard.get(task_id) do
            {:ok, task} ->
              # Find the QA doc
              qa_dir = Shazam.QAManager.qa_dir()
              qa_files = if File.dir?(qa_dir) do
                File.ls!(qa_dir) |> Enum.find(fn f -> String.starts_with?(f, task_id) end)
              end

              if qa_files do
                qa_path = Path.join(qa_dir, qa_files)
                prompt = Shazam.QAManager.build_qa_prompt(task, qa_path)

                # Find QA agent
                agents = Helpers.deep_get(state, [:company, :agents]) || []
                qa_agent = Enum.find(agents, fn a ->
                  role = String.downcase(a[:role] || "")
                  String.contains?(role, "qa") or String.contains?(role, "test")
                end)
                qa_name = if qa_agent, do: qa_agent[:name], else: Helpers.find_pm_name(state)

                Shazam.TaskBoard.create(%{
                  title: "QA Validate: #{task.title}",
                  assigned_to: qa_name,
                  created_by: "qa_system",
                  company: company_name,
                  description: prompt
                })
                Helpers.send_event(state.port, qa_name, "task_created", "QA validation task created for #{task_id}")
              else
                Helpers.send_event(state.port, "system", "error", "No QA doc found for #{task_id}. Run /qa --generate #{task_id}")
              end
            _ ->
              Helpers.send_event(state.port, "system", "error", "Task #{task_id} not found")
          end
        end

      true ->
        Helpers.send_event(state.port, "system", "error", "Unknown /qa command. Use /qa, /qa --generate <id>, /qa --validate <id>, /qa --report, /qa --auto on|off")
    end

    Status.send_status(state)
    state
  end

  defp list_memory_files(dir, prefix) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          display = if prefix == "", do: entry, else: "#{prefix}/#{entry}"
          if File.dir?(path) do
            list_memory_files(path, display)
          else
            [display]
          end
        end)
      _ -> []
    end
  end
end

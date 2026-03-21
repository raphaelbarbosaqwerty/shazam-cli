defmodule Shazam.PlanManager do
  @moduledoc "Manages execution plans — create, approve, track, re-plan."

  @plans_dir ".shazam/plans"

  def plans_dir do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    Path.join(workspace, @plans_dir)
  end

  def ensure_dir do
    dir = plans_dir()
    File.mkdir_p!(dir)
    dir
  end

  @doc "Save a plan to a .md file."
  def save_plan(plan) do
    dir = ensure_dir()
    path = Path.join(dir, "#{plan.id}.md")
    content = render_plan(plan)
    File.write!(path, content)
    {:ok, path}
  end

  @doc "Read a plan from a .md file."
  def read_plan(plan_id) do
    dir = plans_dir()
    path = Path.join(dir, "#{plan_id}.md")
    case File.read(path) do
      {:ok, content} -> parse_plan(plan_id, content)
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "List all plans."
  def list_plans do
    dir = plans_dir()
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn f ->
        plan_id = String.trim_trailing(f, ".md")
        case read_plan(plan_id) do
          {:ok, plan} -> plan
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc "Generate a unique plan ID."
  def next_id do
    existing = list_plans()
    max_num = existing
      |> Enum.map(fn p ->
        case Regex.run(~r/plan_(\d+)/, p.id) do
          [_, num] -> String.to_integer(num)
          _ -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)
    "plan_#{max_num + 1}"
  end

  @doc "Create tasks from an approved plan."
  def create_tasks_from_plan(plan, company_name) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      # Track task IDs for dependency mapping
      task_map = %{}

      {_map, created} = Enum.reduce(plan.tasks, {task_map, 0}, fn task_entry, {map, count} ->
        depends_on = if task_entry[:depends_on] do
          # Resolve dependency to actual task ID if possible
          Map.get(map, task_entry.depends_on, task_entry.depends_on)
        else
          nil
        end

        {:ok, created_task} = Shazam.TaskBoard.create(%{
          title: task_entry.title,
          assigned_to: task_entry.assigned_to,
          created_by: "plan:#{plan.id}",
          company: company_name,
          depends_on: depends_on,
          description: task_entry[:description] || task_entry.title
        })

        new_map = Map.put(map, task_entry.title, created_task.id)
        {new_map, count + 1}
      end)

      # Update plan status
      updated_plan = %{plan | status: "active"}
      save_plan(updated_plan)

      {:ok, created}
    else
      {:error, :task_board_not_available}
    end
  end

  @doc "Build a prompt for the PM to create a plan."
  def build_plan_prompt(description) do
    workspace_context = build_workspace_context()

    """
    Create a detailed execution plan for the following request:

    #{description}
    #{workspace_context}
    Analyze the codebase first to understand the current state, then create a phased plan.

    IMPORTANT: Output your plan as a JSON block in this exact format:

    ```json
    {
      "title": "Short plan title",
      "phases": [
        {
          "name": "Phase 1: Foundation",
          "tasks": [
            {
              "title": "Task description",
              "assigned_to": "agent_name",
              "depends_on": null,
              "description": "Detailed description of what to do"
            },
            {
              "title": "Another task",
              "assigned_to": "agent_name",
              "depends_on": "Task description",
              "description": "This depends on the first task"
            }
          ]
        },
        {
          "name": "Phase 2: Features",
          "tasks": [...]
        }
      ]
    }
    ```

    Rules:
    - Use the actual agent names from the company (check /agents)
    - Set depends_on to the TITLE of the task it depends on, or null if independent
    - Tasks within the same phase CAN run in parallel if they don't depend on each other
    - Tasks that depend on previous phase tasks MUST have depends_on set
    - Be specific in descriptions — include file paths, function names, acceptance criteria
    - Assign tasks based on agent roles (devs implement, QA tests, PM coordinates)
    - When multiple workspaces/repositories exist, be EXPLICIT about which workspace each task belongs to
    - Include the full file path relative to the workspace root in task descriptions
    - Assign agents that have the matching workspace configured
    """
  end

  @doc "Parse a plan from the PM's JSON output."
  def parse_plan_from_output(plan_id, output) do
    case extract_json(output) do
      {:ok, %{"title" => title, "phases" => phases}} ->
        tasks = phases
          |> Enum.flat_map(fn phase ->
            phase_name = phase["name"] || "Unknown Phase"
            (phase["tasks"] || [])
            |> Enum.map(fn t ->
              %{
                title: t["title"],
                assigned_to: t["assigned_to"],
                depends_on: t["depends_on"],
                description: t["description"] || t["title"],
                phase: phase_name
              }
            end)
          end)

        {:ok, %{
          id: plan_id,
          title: title,
          status: "draft",
          tasks: tasks,
          created_at: DateTime.to_iso8601(DateTime.utc_now())
        }}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp render_plan(plan) do
    frontmatter = [
      "---",
      "id: #{plan.id}",
      "title: \"#{plan.title}\"",
      "status: #{plan.status}",
      "created_at: #{plan[:created_at] || DateTime.to_iso8601(DateTime.utc_now())}",
      "---"
    ] |> Enum.join("\n")

    # Group tasks by phase
    phases = plan.tasks
      |> Enum.group_by(fn t -> t[:phase] || "Tasks" end)

    body = phases
      |> Enum.map(fn {phase, tasks} ->
        task_lines = tasks |> Enum.map(fn t ->
          checkbox = if plan.status == "completed", do: "[x]", else: "[ ]"
          dep = if t[:depends_on], do: "\n  depends_on: #{t.depends_on}", else: ""
          agent = if t[:assigned_to], do: " → #{t.assigned_to}", else: ""
          "- #{checkbox} #{t.title}#{agent}#{dep}"
        end) |> Enum.join("\n")
        "\n## #{phase}\n#{task_lines}"
      end)
      |> Enum.join("\n")

    frontmatter <> "\n" <> body <> "\n"
  end

  defp parse_plan(plan_id, content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)/s, content) do
      [_, frontmatter, body] ->
        meta = parse_frontmatter(frontmatter)
        tasks = parse_plan_tasks(body)
        {:ok, %{
          id: plan_id,
          title: meta["title"] || "Untitled Plan",
          status: meta["status"] || "draft",
          created_at: meta["created_at"],
          tasks: tasks
        }}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_frontmatter(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value) |> String.trim("\""))
        _ -> acc
      end
    end)
  end

  defp parse_plan_tasks(body) do
    current_phase = "Tasks"

    body
    |> String.split("\n")
    |> Enum.reduce({current_phase, []}, fn line, {phase, tasks} ->
      cond do
        String.starts_with?(String.trim(line), "## ") ->
          new_phase = String.trim(line) |> String.trim_leading("## ")
          {new_phase, tasks}
        Regex.match?(~r/^- \[[ x]\] /, String.trim(line)) ->
          task_line = String.trim(line) |> String.slice(6..-1//1)
          {title, agent} = case String.split(task_line, " → ", parts: 2) do
            [t, a] -> {String.trim(t), String.trim(a)}
            [t] -> {String.trim(t), nil}
          end
          task = %{title: title, assigned_to: agent, phase: phase, depends_on: nil}
          {phase, tasks ++ [task]}
        String.contains?(line, "depends_on:") ->
          dep = line |> String.split("depends_on:") |> List.last() |> String.trim()
          case List.last(tasks) do
            nil -> {phase, tasks}
            last_task ->
              updated = %{last_task | depends_on: dep}
              {phase, List.replace_at(tasks, -1, updated)}
          end
        true ->
          {phase, tasks}
      end
    end)
    |> elem(1)
  end

  defp build_workspace_context do
    workspaces = Application.get_env(:shazam, :workspaces, %{})
    if workspaces == nil or workspaces == %{} do
      ""
    else
      lines = workspaces
        |> Enum.map(fn {name, config} ->
          path = if is_map(config), do: config[:path] || config["path"] || Map.get(config, :path, ""), else: ""
          "  - #{name}: #{path}"
        end)
        |> Enum.join("\n")

      """

      WORKSPACES/REPOSITORIES available:
      #{lines}

      Each agent is assigned to a specific workspace. When creating tasks, be explicit about WHICH workspace/repository the task applies to. Include the workspace name in the task description.
      """
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/```json\s*\n(.*?)\n```/s, text) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, "Invalid JSON in plan output"}
        end
      nil ->
        case Jason.decode(text) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, "No JSON plan block found"}
        end
    end
  end
end

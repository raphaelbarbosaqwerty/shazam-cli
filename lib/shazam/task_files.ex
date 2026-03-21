defmodule Shazam.TaskFiles do
  @moduledoc "Sync tasks between ETS TaskBoard and .shazam/tasks/ markdown files."

  @tasks_dir ".shazam/tasks"

  @doc "Returns the tasks directory path for the current workspace."
  def tasks_dir do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    Path.join(workspace, @tasks_dir)
  end

  @doc "Ensure the tasks directory exists."
  def ensure_dir do
    dir = tasks_dir()
    File.mkdir_p!(dir)
    dir
  end

  @doc "Write a task to a markdown file."
  def write_task(task) do
    dir = ensure_dir()
    filename = "#{task.id}.md"
    path = Path.join(dir, filename)

    content = render_task(task)
    File.write!(path, content)
    path
  end

  @doc "Read all task files from disk and return as list of maps."
  def read_all do
    dir = tasks_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn filename ->
        path = Path.join(dir, filename)
        parse_task_file(path)
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc "Update only the frontmatter status and result of an existing task file."
  def update_status(task_id, status, result \\ nil) do
    dir = tasks_dir()
    path = Path.join(dir, "#{task_id}.md")

    if File.exists?(path) do
      case parse_task_file(path) do
        nil ->
          :ok

        task ->
          updated =
            task
            |> Map.put(:status, to_string(status))
            |> then(fn t -> if result, do: Map.put(t, :result, result), else: t end)
            |> Map.put(:updated_at, DateTime.to_iso8601(DateTime.utc_now()))

          # Add completed_at if completing
          updated =
            if to_string(status) in ["completed", "failed"] do
              Map.put(updated, :completed_at, DateTime.to_iso8601(DateTime.utc_now()))
            else
              updated
            end

          write_task_from_map(updated, path)
      end
    end
  end

  @doc "Delete a task file."
  def delete_task(task_id) do
    dir = tasks_dir()
    path = Path.join(dir, "#{task_id}.md")
    if File.exists?(path), do: File.rm(path)
  end

  @doc "Sync tasks from TaskBoard to files (export)."
  def sync_to_files(tasks) do
    ensure_dir()

    Enum.each(tasks, fn task ->
      write_task(task)
    end)
  end

  @doc "Sync tasks from files to TaskBoard (import). Skips tasks already in ETS."
  def sync_from_files do
    tasks = read_all()
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      # Get all existing task IDs to avoid duplicates
      existing_ids = try do
        Shazam.TaskBoard.list()
        |> Enum.map(& &1.id)
        |> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end

      Enum.each(tasks, fn task_map ->
        # Skip if task ID already exists OR if title+company match
        already_exists = MapSet.member?(existing_ids, task_map.id) or
          try do
            Shazam.TaskBoard.list()
            |> Enum.any?(fn t -> t.title == task_map.title and t.company == task_map[:company] end)
          catch
            _, _ -> false
          end

        unless already_exists do
          status = case task_map.status do
            s when is_atom(s) -> s
            "completed" -> :completed
            "failed" -> :failed
            "pending" -> :pending
            "in_progress" -> :in_progress
            "awaiting_approval" -> :awaiting_approval
            "paused" -> :paused
            "rejected" -> :rejected
            "deleted" -> :deleted
            _ -> :pending
          end

          # Reset in_progress → pending (interrupted during shutdown)
          status = if status == :in_progress, do: :pending, else: status

          now = DateTime.utc_now()
          # Truncate large results to prevent memory issues on import
          result = case task_map[:result] do
            r when is_binary(r) and byte_size(r) > 10_000 -> String.slice(r, 0..10_000) <> "\n[...truncated]"
            r -> r
          end

          task = %{
            id: task_map.id,
            title: task_map.title,
            description: task_map[:description],
            status: status,
            assigned_to: task_map[:assigned_to],
            created_by: task_map[:created_by],
            company: task_map[:company],
            result: result,
            parent_task_id: task_map[:parent_task_id],
            depends_on: task_map[:depends_on],
            attachments: task_map[:attachments] || [],
            retry_count: task_map[:retry_count] || 0,
            max_retries: task_map[:max_retries] || 2,
            last_error: nil,
            created_at: task_map[:created_at] || now,
            updated_at: task_map[:updated_at] || now
          }

          try do
            Shazam.TaskBoard.import_task(task)
          catch
            _, _ -> :ok
          end
        end
      end)
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp render_task(task) do
    status = to_string(task.status)
    assigned = task.assigned_to || "unassigned"
    created_by = task.created_by || "system"
    company = if Map.has_key?(task, :company), do: task.company, else: nil
    title = task.title || ""
    description = task[:description] || task.title || ""

    result =
      cond do
        is_binary(task[:result]) -> task.result
        is_binary(task.result) -> task.result
        true -> nil
      end

    created_at =
      cond do
        is_struct(task[:created_at], DateTime) -> DateTime.to_iso8601(task.created_at)
        is_binary(task[:created_at]) -> task.created_at
        true -> DateTime.to_iso8601(DateTime.utc_now())
      end

    frontmatter =
      [
        "---",
        "id: #{task.id}",
        "title: \"#{String.replace(title, "\"", "\\\"")}\"",
        "status: #{status}",
        "assigned_to: #{assigned}",
        "created_by: #{created_by}",
        if(company, do: "company: #{company}", else: nil),
        "created_at: #{created_at}",
        "---"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body = "\n\n## Description\n\n#{description}\n"

    body =
      if result do
        body <> "\n## Result\n\n#{result}\n"
      else
        body
      end

    frontmatter <> body
  end

  defp write_task_from_map(task_map, path) do
    frontmatter_fields =
      [
        "---",
        "id: #{task_map.id}",
        "title: \"#{String.replace(task_map.title || "", "\"", "\\\"")}\"",
        "status: #{task_map.status}",
        "assigned_to: #{task_map[:assigned_to] || "unassigned"}",
        "created_by: #{task_map[:created_by] || "system"}",
        if(task_map[:company], do: "company: #{task_map.company}", else: nil),
        "created_at: #{task_map[:created_at] || ""}",
        if(task_map[:completed_at], do: "completed_at: #{task_map.completed_at}", else: nil),
        if(task_map[:updated_at], do: "updated_at: #{task_map.updated_at}", else: nil),
        "---"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body = "\n\n## Description\n\n#{task_map[:description] || task_map.title || ""}\n"

    body =
      if task_map[:result] do
        body <> "\n## Result\n\n#{task_map.result}\n"
      else
        body
      end

    File.write!(path, frontmatter_fields <> body)
  end

  defp parse_task_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)/s, content) do
          [_, frontmatter, body] ->
            meta = parse_frontmatter(frontmatter)
            description = extract_section(body, "Description")
            result = extract_section(body, "Result")

            if meta["id"] do
              %{
                id: meta["id"],
                title: meta["title"] || Path.basename(path, ".md"),
                status: meta["status"] || "pending",
                assigned_to: meta["assigned_to"],
                created_by: meta["created_by"],
                company: meta["company"],
                created_at: meta["created_at"],
                completed_at: meta["completed_at"],
                updated_at: meta["updated_at"],
                description: description,
                result: result
              }
            else
              nil
            end

          _ ->
            nil
        end

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_frontmatter(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] ->
          value = value |> String.trim() |> String.trim("\"")

          if value == "" or value == "null",
            do: acc,
            else: Map.put(acc, String.trim(key), value)

        _ ->
          acc
      end
    end)
  end

  defp extract_section(body, section_name) do
    case Regex.run(~r/## #{section_name}\s*\n\n(.*?)(?=\n## |\z)/s, body) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end
end

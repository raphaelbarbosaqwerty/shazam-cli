# Plugin: JSON log of all task events
# Place in .shazam/plugins/04_json_logger.ex
#
# Saves structured logs to .shazam/logs/events.json (never committed to git).
# Add .shazam/logs/ to your .gitignore.
defmodule ShazamPlugin.JsonLogger do
  use Shazam.Plugin

  @log_dir ".shazam/logs"
  @log_file ".shazam/logs/events.json"

  @impl true
  def on_init(_ctx) do
    File.mkdir_p!(@log_dir)
    :ok
  end

  @impl true
  def after_task_create(task, ctx) do
    log_event("task_created", %{
      task_id: task.id,
      title: task.title,
      assigned_to: task.assigned_to,
      company: ctx.company_name
    })
    {:ok, task}
  end

  @impl true
  def after_task_complete(task_id, result, ctx) do
    preview = result |> to_string() |> String.slice(0..500)
    log_event("task_completed", %{
      task_id: task_id,
      result_preview: preview,
      company: ctx.company_name
    })
    {:ok, result}
  end

  defp log_event(event_type, data) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event_type,
      data: data
    }

    line = Jason.encode!(entry) <> "\n"
    File.write(@log_file, line, [:append])
  rescue
    _ -> :ok
  end
end

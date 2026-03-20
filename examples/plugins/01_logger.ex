# Example plugin: log all task events to a file
# Place in .shazam/plugins/01_logger.ex
defmodule ShazamPlugin.Logger do
  use Shazam.Plugin

  @log_file ".shazam/plugin_events.log"

  @impl true
  def on_init(ctx) do
    log("init", "Shazam started with #{length(ctx.agents)} agents")
    :ok
  end

  @impl true
  def after_task_create(task, _ctx) do
    log("task_created", "#{task.id}: #{task.title} -> #{task.assigned_to}")
    {:ok, task}
  end

  @impl true
  def after_task_complete(task_id, result, _ctx) do
    preview = result |> to_string() |> String.slice(0..100)
    log("task_completed", "#{task_id}: #{preview}")
    {:ok, result}
  end

  defp log(event, message) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
    line = "[#{timestamp}] [#{event}] #{message}\n"
    File.write(@log_file, line, [:append])
  end
end

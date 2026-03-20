# Example plugin: send webhook on task completion
# Place in .shazam/plugins/02_webhook.ex
#
# Configure in shazam.yaml:
#   plugins:
#     - name: webhook
#       config:
#         url: "https://hooks.slack.com/services/..."
defmodule ShazamPlugin.Webhook do
  use Shazam.Plugin

  @impl true
  def after_task_complete(task_id, result, ctx) do
    url = ctx.plugin_config["url"]

    if url do
      payload = Jason.encode!(%{
        text: "Task #{task_id} completed in #{ctx.company_name}",
        result_preview: result |> to_string() |> String.slice(0..200)
      })

      # Fire and forget — don't block the pipeline
      spawn(fn ->
        System.cmd("curl", [
          "-s", "-X", "POST",
          "-H", "Content-type: application/json",
          "-d", payload,
          url
        ])
      end)
    end

    {:ok, result}
  end
end

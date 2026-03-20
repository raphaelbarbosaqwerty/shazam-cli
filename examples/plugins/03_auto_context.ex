# Example plugin: auto-inject project context into agent queries
# Place in .shazam/plugins/03_auto_context.ex
defmodule ShazamPlugin.AutoContext do
  use Shazam.Plugin

  @impl true
  def before_query(prompt, _agent_name, _ctx) do
    extra_context = load_project_context()

    if extra_context != "" do
      {:ok, extra_context <> "\n\n" <> prompt}
    else
      {:ok, prompt}
    end
  end

  defp load_project_context do
    path = ".shazam/project_context.md"
    case File.read(path) do
      {:ok, content} -> "## Project Context\n#{content}"
      _ -> ""
    end
  end
end

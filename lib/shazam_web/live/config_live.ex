defmodule ShazamWeb.ConfigLive do
  use ShazamWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    config_yaml = load_config_yaml()
    provider = detect_provider()
    plugins = load_plugins()
    git_context = load_git_context()

    {:ok,
     assign(socket,
       page_title: "Config",
       config_yaml: config_yaml,
       provider: provider,
       plugins: plugins,
       git_context: git_context
     )}
  end

  @impl true
  def handle_event("reload_plugins", _params, socket) do
    try do
      Shazam.PluginManager.reload()
    catch
      _, _ -> :ok
    end

    plugins = load_plugins()
    {:noreply, assign(socket, plugins: plugins)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold text-zinc-100">Configuration</h1>

      <%!-- Provider --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
        <h2 class="text-lg font-semibold text-zinc-100 mb-3">Provider</h2>
        <div class="flex items-center gap-3">
          <span class="inline-flex items-center px-3 py-1.5 rounded-lg bg-zinc-800 text-sm text-emerald-400 font-medium">
            {@provider}
          </span>
        </div>
      </div>

      <%!-- YAML Config --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
        <h2 class="text-lg font-semibold text-zinc-100 mb-3">YAML Configuration</h2>
        <div :if={@config_yaml != ""} class="bg-zinc-950 border border-zinc-800 rounded-lg p-4 overflow-x-auto">
          <pre class="font-mono text-sm text-zinc-300 whitespace-pre">{@config_yaml}</pre>
        </div>
        <p :if={@config_yaml == ""} class="text-sm text-zinc-500">
          No configuration file found. Looked for .shazam/shazam.yaml and shazam.yaml.
        </p>
      </div>

      <%!-- Plugins --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-semibold text-zinc-100">Plugins</h2>
          <button
            phx-click="reload_plugins"
            class="px-3 py-1.5 bg-zinc-800 hover:bg-zinc-700 text-sm text-zinc-300 rounded-lg transition-colors"
          >
            Reload Plugins
          </button>
        </div>
        <div :if={@plugins != []} class="space-y-2">
          <div
            :for={plugin <- @plugins}
            class="flex items-center gap-3 px-4 py-2.5 bg-zinc-800/50 rounded-lg"
          >
            <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
            <span class="text-sm text-zinc-200 font-mono">{inspect(plugin)}</span>
          </div>
        </div>
        <p :if={@plugins == []} class="text-sm text-zinc-500">
          No plugins loaded.
        </p>
      </div>

      <%!-- Git Context --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
        <h2 class="text-lg font-semibold text-zinc-100 mb-3">Git Context</h2>
        <div :if={@git_context != ""} class="bg-zinc-950 border border-zinc-800 rounded-lg p-4 overflow-x-auto">
          <pre class="font-mono text-sm text-zinc-300 whitespace-pre">{@git_context}</pre>
        </div>
        <p :if={@git_context == ""} class="text-sm text-zinc-500">
          Not a git repository or git context unavailable.
        </p>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────

  defp load_config_yaml do
    paths = [
      ".shazam/shazam.yaml",
      "shazam.yaml",
      ".shazam/shazam.yml",
      "shazam.yml"
    ]

    Enum.find_value(paths, "", fn path ->
      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    end)
  end

  defp detect_provider do
    try do
      cond do
        env = System.get_env("SHAZAM_PROVIDER") -> env
        System.get_env("ANTHROPIC_API_KEY") -> "Anthropic (Claude)"
        System.get_env("OPENAI_API_KEY") -> "OpenAI"
        true -> "Not configured"
      end
    catch
      _, _ -> "Unknown"
    end
  end

  defp load_plugins do
    try do
      Shazam.PluginManager.list_plugins()
    catch
      _, _ -> []
    end
  end

  defp load_git_context do
    workspace = File.cwd!()

    try do
      Shazam.GitContext.build_context(workspace)
    catch
      _, _ -> ""
    end
  end
end

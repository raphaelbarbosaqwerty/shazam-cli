defmodule Shazam.PluginManager do
  @moduledoc """
  GenServer that manages loaded plugins and executes event pipelines.

  Plugins are loaded from `.shazam/plugins/*.ex` on `/start`.
  The pipeline is zero-cost when no plugins are loaded.
  """

  use GenServer
  require Logger

  # ── Public API ────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Load plugins from workspace directory."
  def load_plugins(company_name, workspace, plugin_configs \\ []) do
    GenServer.call(__MODULE__, {:load, company_name, workspace, plugin_configs})
  end

  @doc "Reload plugins from disk."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "List loaded plugin modules."
  def list_plugins do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Run the event pipeline through all loaded plugins.

  Returns `{:ok, data}` or `{:halt, reason}`.
  Zero-cost (no GenServer call) when no plugins are loaded.
  """
  def run_pipeline(event, data, opts \\ []) do
    # Fast path: skip GenServer entirely when no plugins loaded
    case :persistent_term.get({__MODULE__, :plugins}, []) do
      [] -> {:ok, data}
      plugins -> do_run_pipeline(plugins, event, data, opts)
    end
  end

  @doc "Fire an event without caring about the return value (for observe-only hooks)."
  def notify(event, data, opts \\ []) do
    case :persistent_term.get({__MODULE__, :plugins}, []) do
      [] -> :ok
      plugins ->
        context = build_context(opts)
        Enum.each(plugins, fn {plugin, plugin_config, allowed_events} ->
          if event_allowed?(event, allowed_events) do
            ctx = Map.put(context, :plugin_config, plugin_config)
            safe_notify(plugin, event, data, ctx)
          end
        end)
    end
  end

  # ── Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :plugins}, [])
    {:ok, %{plugins: [], company_name: nil, workspace: nil, plugin_configs: []}}
  end

  @all_events ~w(on_init before_task_create after_task_create before_task_complete after_task_complete before_query after_query on_tool_use)a

  @impl true
  def handle_call({:load, company_name, workspace, plugin_configs}, _from, _state) do
    modules = Shazam.PluginLoader.load_all(workspace)

    # Pair each module with its config and event filter from YAML
    plugins =
      Enum.map(modules, fn mod ->
        mod_name = mod |> Module.split() |> List.last() |> Macro.underscore()

        config =
          Enum.find(plugin_configs, %{}, fn pc ->
            pc_name = pc[:name] || pc["name"] || ""
            Macro.underscore(pc_name) == mod_name
          end)

        plugin_config = config[:config] || config["config"] || %{}
        enabled = Map.get(config, :enabled, Map.get(config, "enabled", true))
        events = parse_events(config[:events] || config["events"])

        {mod, plugin_config, enabled, events}
      end)
      |> Enum.filter(fn {_mod, _config, enabled, _events} -> enabled end)
      |> Enum.map(fn {mod, config, _enabled, events} -> {mod, config, events} end)

    # Store in persistent_term for lock-free reads
    :persistent_term.put({__MODULE__, :plugins}, plugins)

    if plugins != [] do
      names = Enum.map_join(plugins, ", ", fn {mod, _, _} -> inspect(mod) end)
      Logger.info("[PluginManager] Loaded #{length(plugins)} plugin(s): #{names}")
    end

    state = %{
      plugins: plugins,
      company_name: company_name,
      workspace: workspace,
      plugin_configs: plugin_configs
    }

    {:reply, {:ok, length(plugins)}, state}
  end

  def handle_call(:reload, _from, state) do
    if state.workspace do
      modules = Shazam.PluginLoader.load_all(state.workspace)

      plugins =
        Enum.map(modules, fn mod ->
          mod_name = mod |> Module.split() |> List.last() |> Macro.underscore()

          config =
            Enum.find(state.plugin_configs, %{}, fn pc ->
              pc_name = pc[:name] || pc["name"] || ""
              Macro.underscore(pc_name) == mod_name
            end)

          plugin_config = config[:config] || config["config"] || %{}
          events = parse_events(config[:events] || config["events"])
          {mod, plugin_config, events}
        end)

      :persistent_term.put({__MODULE__, :plugins}, plugins)
      {:reply, {:ok, length(plugins)}, %{state | plugins: plugins}}
    else
      {:reply, {:ok, 0}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state.plugins, state}
  end

  # ── Pipeline Execution ────────────────────────────────────

  defp do_run_pipeline(plugins, event, data, opts) do
    context = build_context(opts)

    Enum.reduce_while(plugins, {:ok, data}, fn {plugin, plugin_config, allowed_events}, {:ok, acc} ->
      if event_allowed?(event, allowed_events) and has_callback?(plugin, event) do
        ctx = Map.put(context, :plugin_config, plugin_config)
        case safe_call(plugin, event, acc, ctx) do
          {:ok, new_data} -> {:cont, {:ok, new_data}}
          {:halt, reason} -> {:halt, {:halt, reason}}
          :ok -> {:cont, {:ok, acc}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp safe_call(plugin, event, data, context) do
    args = build_args(event, data, context)
    apply(plugin, event, args)
  rescue
    e ->
      Logger.error("[Plugin] #{inspect(plugin)}.#{event} crashed: #{Exception.message(e)}")
      {:ok, data}
  catch
    kind, reason ->
      Logger.error("[Plugin] #{inspect(plugin)}.#{event} #{kind}: #{inspect(reason)}")
      {:ok, data}
  end

  defp safe_notify(plugin, event, data, context) do
    if has_callback?(plugin, event) do
      args = build_args(event, data, context)
      apply(plugin, event, args)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp event_allowed?(_event, nil), do: true
  defp event_allowed?(_event, :all), do: true
  defp event_allowed?(event, events) when is_list(events), do: event in events

  defp parse_events(nil), do: :all
  defp parse_events(events) when is_list(events) do
    parsed = Enum.map(events, fn
      e when is_atom(e) -> e
      e when is_binary(e) -> String.to_atom(e)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1 in @all_events))

    if parsed == [], do: :all, else: parsed
  end
  defp parse_events(_), do: :all

  defp has_callback?(plugin, event) do
    arity = event_arity(event)
    function_exported?(plugin, event, arity)
  end

  # ── Argument Building ─────────────────────────────────────

  defp build_args(:on_init, _data, ctx), do: [ctx]
  defp build_args(:before_task_create, attrs, ctx), do: [attrs, ctx]
  defp build_args(:after_task_create, task, ctx), do: [task, ctx]
  defp build_args(:before_task_complete, {task_id, result}, ctx), do: [task_id, result, ctx]
  defp build_args(:after_task_complete, {task_id, result}, ctx), do: [task_id, result, ctx]
  defp build_args(:before_query, {prompt, agent}, ctx), do: [prompt, agent, ctx]
  defp build_args(:after_query, {result, agent}, ctx), do: [result, agent, ctx]
  defp build_args(:on_tool_use, {tool, input, agent}, ctx), do: [tool, input, agent, ctx]
  defp build_args(_event, data, ctx), do: [data, ctx]

  defp event_arity(:on_init), do: 1
  defp event_arity(:on_tool_use), do: 4
  defp event_arity(:before_task_complete), do: 3
  defp event_arity(:after_task_complete), do: 3
  defp event_arity(:before_query), do: 3
  defp event_arity(:after_query), do: 3
  defp event_arity(_), do: 2

  defp build_context(opts) do
    company_name = opts[:company_name]

    agents =
      try do
        if company_name && Code.ensure_loaded?(Shazam.Company) do
          Shazam.Company.get_agents(company_name)
        else
          []
        end
      catch
        _, _ -> []
      end

    tasks =
      try do
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          if company_name do
            Shazam.TaskBoard.list(%{company: company_name})
          else
            Shazam.TaskBoard.list()
          end
        else
          []
        end
      catch
        _, _ -> []
      end

    %{
      company_name: company_name,
      agents: agents,
      tasks: tasks,
      plugin_config: %{}
    }
  end
end

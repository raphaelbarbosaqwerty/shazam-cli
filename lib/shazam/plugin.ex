defmodule Shazam.Plugin do
  @moduledoc """
  Behaviour for Shazam plugins.

  Plugins are Elixir modules placed in `.shazam/plugins/*.ex` that hook into
  the agent orchestration lifecycle. Each callback is optional — implement only
  the events you need.

  ## Events

  "before" callbacks can mutate the input data or halt the operation:
  - `before_task_create/2` — modify task attributes before creation
  - `before_task_complete/3` — modify result before marking complete
  - `before_query/3` — modify prompt before sending to agent

  "after" callbacks can mutate the output:
  - `after_task_create/2` — react to or modify created task
  - `after_task_complete/3` — react to or modify completion result
  - `after_query/3` — modify agent response

  Notification-only:
  - `on_init/1` — called when /start boots agents
  - `on_tool_use/4` — observe tool calls (cannot mutate)

  ## Return values

  - `{:ok, data}` — continue pipeline with (possibly modified) data
  - `{:halt, reason}` — stop pipeline, cancel the operation (before events only)
  - `:ok` — continue (for on_init, on_tool_use)

  ## Context

  Every callback receives a context map:

      %{
        company_name: "MyCompany",
        agents: [%{name: "pm", role: "Project Manager", ...}, ...],
        tasks: [%{id: "task_1", title: "...", status: :pending, ...}, ...],
        plugin_config: %{"webhook_url" => "..."}
      }

  ## Example

      # .shazam/plugins/slack_notify.ex
      defmodule ShazamPlugin.SlackNotify do
        @behaviour Shazam.Plugin

        @impl true
        def after_task_complete(_task_id, result, _ctx) do
          System.cmd("curl", ["-s", "-X", "POST", System.get_env("SLACK_WEBHOOK"),
            "-d", Jason.encode!(%{text: "Task done!"})])
          {:ok, result}
        end
      end
  """

  @type context :: %{
          company_name: String.t(),
          agents: [map()],
          tasks: [map()],
          plugin_config: map()
        }

  # Lifecycle
  @callback on_init(context()) :: :ok | {:error, term()}

  # Task creation
  @callback before_task_create(attrs :: map(), context()) :: {:ok, map()} | {:halt, term()}
  @callback after_task_create(task :: map(), context()) :: {:ok, map()}

  # Task completion
  @callback before_task_complete(task_id :: String.t(), result :: term(), context()) ::
              {:ok, term()} | {:halt, term()}
  @callback after_task_complete(task_id :: String.t(), result :: term(), context()) ::
              {:ok, term()}

  # Agent query
  @callback before_query(prompt :: String.t(), agent_name :: String.t(), context()) ::
              {:ok, String.t()} | {:halt, term()}
  @callback after_query(result :: term(), agent_name :: String.t(), context()) ::
              {:ok, term()}

  # Tool use (observe-only)
  @callback on_tool_use(
              tool_name :: String.t(),
              input :: map(),
              agent_name :: String.t(),
              context()
            ) :: :ok

  @optional_callbacks [
    on_init: 1,
    before_task_create: 2,
    after_task_create: 2,
    before_task_complete: 3,
    after_task_complete: 3,
    before_query: 3,
    after_query: 3,
    on_tool_use: 4
  ]

  @doc "Helper macro — `use Shazam.Plugin` adds the behaviour."
  defmacro __using__(_opts) do
    quote do
      @behaviour Shazam.Plugin
    end
  end
end

defmodule Shazam.AgentInbox do
  @moduledoc """
  A simple per-agent message queue for user-sent messages.
  When the user types in the terminal, messages are queued here.
  If the agent is idle, execution is triggered immediately.
  If busy, messages wait until the current task finishes.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a user message for the given agent."
  def push(agent_name, message) do
    GenServer.call(__MODULE__, {:push, agent_name, message})
  end

  @doc "Pop the next pending message for the agent. Returns nil if empty."
  def pop(agent_name) do
    GenServer.call(__MODULE__, {:pop, agent_name})
  end

  @doc "Check if agent has pending messages."
  def has_pending?(agent_name) do
    GenServer.call(__MODULE__, {:has_pending?, agent_name})
  end

  @doc "Pop all pending messages for the agent."
  def pop_all(agent_name) do
    GenServer.call(__MODULE__, {:pop_all, agent_name})
  end

  @doc """
  Execute all pending messages for an agent on their existing session.
  Call this from a spawned process (not inside the GenServer).
  """
  def execute_pending(agent_name) do
    messages = pop_all(agent_name)
    if messages == [], do: :noop, else: do_execute(agent_name, messages)
  end

  defp do_execute(agent_name, messages) do
    # Combine all pending messages into one prompt
    combined = messages
      |> Enum.map(fn %{message: msg} -> msg end)
      |> Enum.join("\n\n---\n\n")

    prompt = """
    [User Message — sent directly via terminal]

    #{combined}

    Respond to the user's message above. If it contains instructions or hints for your current work, follow them.
    """

    Logger.info("[AgentInbox] Executing #{length(messages)} pending message(s) for '#{agent_name}'")

    # Try to get the agent's existing session from the pool
    # We need the agent's session opts — resolve from company
    company_name = get_company_name()
    agent_profile = Shazam.TaskScheduler.resolve_agent_profile(company_name, agent_name)

    unless agent_profile do
      Logger.warning("[AgentInbox] Agent '#{agent_name}' not found — cannot execute message")
      Shazam.API.EventBus.broadcast(%{
        event: "agent_output",
        agent: agent_name,
        type: "result",
        content: "Error: Agent '#{agent_name}' not found"
      })
      return_error()
    end

    if agent_profile do
      workspace = Application.get_env(:shazam, :workspace, nil)
      base_prompt = agent_profile.system_prompt || "You are #{agent_profile.role}."

      session_opts = [
        system_prompt: base_prompt,
        timeout: 300_000,
        permission_mode: :bypass_permissions,
        setting_sources: ["user", "project"],
        env: %{"CLAUDECODE" => ""}
      ]
      |> maybe_add_opt(:allowed_tools, agent_profile.tools, agent_profile.tools != [])
      |> maybe_add_opt(:model, agent_profile.model, agent_profile.model != nil and agent_profile.model != "")
      |> maybe_add_opt(:cwd, workspace, workspace != nil)

      case Shazam.SessionPool.checkout(agent_name, session_opts) do
        {:ok, session_pid, _session_type} ->
          result = Shazam.Orchestrator.execute_on_session(session_pid, agent_name, prompt)
          Shazam.SessionPool.checkin(agent_name)

          case result do
            {:ok, _text, _files} ->
              Logger.info("[AgentInbox] Message executed successfully for '#{agent_name}'")
            {:error, reason} ->
              Logger.error("[AgentInbox] Message execution failed for '#{agent_name}': #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("[AgentInbox] Cannot checkout session for '#{agent_name}': #{inspect(reason)}")
          Shazam.API.EventBus.broadcast(%{
            event: "agent_output",
            agent: agent_name,
            type: "result",
            content: "Error: Could not start session — #{inspect(reason)}"
          })
      end
    end
  end

  defp get_company_name do
    # Find the first active company from the RalphLoop registry
    case Registry.select(Shazam.RalphLoopRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}]) do
      [name | _] -> name
      [] -> nil
    end
  end

  defp maybe_add_opt(opts, _key, _value, false), do: opts
  defp maybe_add_opt(opts, key, value, true), do: Keyword.put(opts, key, value)

  defp return_error, do: :error

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{queues: %{}}}
  end

  @impl true
  def handle_call({:push, agent_name, message}, _from, state) do
    entry = %{message: message, timestamp: DateTime.utc_now()}
    queue = Map.get(state.queues, agent_name, :queue.new())
    queue = :queue.in(entry, queue)
    Logger.info("[AgentInbox] Queued message for '#{agent_name}' (#{:queue.len(queue)} pending)")
    {:reply, :ok, %{state | queues: Map.put(state.queues, agent_name, queue)}}
  end

  def handle_call({:pop, agent_name}, _from, state) do
    case Map.get(state.queues, agent_name) do
      nil ->
        {:reply, nil, state}

      queue ->
        case :queue.out(queue) do
          {{:value, entry}, rest} ->
            queues = if :queue.is_empty(rest),
              do: Map.delete(state.queues, agent_name),
              else: Map.put(state.queues, agent_name, rest)
            {:reply, entry, %{state | queues: queues}}

          {:empty, _} ->
            {:reply, nil, state}
        end
    end
  end

  def handle_call({:has_pending?, agent_name}, _from, state) do
    result = case Map.get(state.queues, agent_name) do
      nil -> false
      queue -> not :queue.is_empty(queue)
    end
    {:reply, result, state}
  end

  def handle_call({:pop_all, agent_name}, _from, state) do
    case Map.pop(state.queues, agent_name) do
      {nil, _} ->
        {:reply, [], state}

      {queue, queues} ->
        messages = :queue.to_list(queue)
        {:reply, messages, %{state | queues: queues}}
    end
  end
end

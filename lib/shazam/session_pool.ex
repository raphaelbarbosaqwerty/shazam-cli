defmodule Shazam.SessionPool do
  @moduledoc """
  Maintains a pool of reusable sessions, one per agent.
  Sessions are kept alive between tasks to preserve context and save tokens.

  Backend-agnostic: delegates session creation/destruction to the active backend.
  For backends that don't support persistent sessions (e.g. Cursor CLI),
  returns virtual session refs that are recreated each time.
  """

  use GenServer
  require Logger

  @idle_timeout :timer.minutes(15)
  @max_tasks_before_reset 8

  defstruct sessions: %{}

  # Keys that define session identity — if these change, session must be recreated.
  @structural_keys [:model, :allowed_tools, :cwd, :add_dir, :permission_mode, :timeout]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets or creates a session for the given agent.
  Returns {:ok, session, :new} for fresh sessions or {:ok, session, :reused} for existing ones.
  """
  def checkout(agent_name, session_opts) do
    GenServer.call(__MODULE__, {:checkout, agent_name, session_opts}, :timer.minutes(2))
  end

  @doc "Marks a session as idle (available for reuse). Does NOT kill it."
  def checkin(agent_name) do
    GenServer.cast(__MODULE__, {:checkin, agent_name})
  end

  @doc "Kills a specific agent's session."
  def kill(agent_name) do
    GenServer.call(__MODULE__, {:kill, agent_name}, :timer.seconds(10))
  end

  @doc "Kills all sessions."
  def kill_all do
    GenServer.call(__MODULE__, :kill_all, :timer.seconds(30))
  end

  @doc "Returns info about all active sessions."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    :timer.send_interval(:timer.minutes(5), :cleanup_idle)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:checkout, agent_name, session_opts}, _from, state) do
    backend = Shazam.Backend.Registry.current()

    if backend.supports_sessions?() do
      checkout_persistent(agent_name, session_opts, backend, state)
    else
      checkout_stateless(agent_name, session_opts, backend, state)
    end
  end

  def handle_call({:kill, agent_name}, _from, state) do
    backend = Shazam.Backend.Registry.current()

    case Map.pop(state.sessions, agent_name) do
      {nil, _} ->
        {:reply, :ok, state}

      {%{session: session}, sessions} ->
        backend.stop_session(session)
        Logger.info("[SessionPool] Killed session for '#{agent_name}'")
        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  def handle_call(:kill_all, _from, state) do
    backend = Shazam.Backend.Registry.current()
    count = map_size(state.sessions)

    Enum.each(state.sessions, fn {name, %{session: session}} ->
      backend.stop_session(session)
      Logger.info("[SessionPool] Killed session for '#{name}'")
    end)

    {:reply, {:ok, count}, %{state | sessions: %{}}}
  end

  def handle_call(:list, _from, state) do
    backend = Shazam.Backend.Registry.current()

    info =
      state.sessions
      |> Enum.map(fn {name, entry} ->
        alive = if backend.supports_sessions?() do
          is_pid(entry.session) and Process.alive?(entry.session)
        else
          true
        end

        %{
          agent: name,
          alive: alive,
          last_used: entry.last_used,
          task_count: entry.task_count,
          backend: backend.name()
        }
      end)

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:checkin, agent_name}, state) do
    case Map.get(state.sessions, agent_name) do
      nil -> {:noreply, state}
      entry ->
        updated = %{entry | last_used: DateTime.utc_now(), in_use: false}
        {:noreply, %{state | sessions: Map.put(state.sessions, agent_name, updated)}}
    end
  end

  @impl true
  def handle_info(:cleanup_idle, state) do
    backend = Shazam.Backend.Registry.current()
    now = DateTime.utc_now()

    {to_kill, to_keep} =
      state.sessions
      |> Enum.split_with(fn {_name, entry} ->
        idle = not Map.get(entry, :in_use, false) and
          DateTime.diff(now, entry.last_used, :millisecond) > @idle_timeout

        dead = if backend.supports_sessions?() do
          is_pid(entry.session) and not Process.alive?(entry.session)
        else
          false
        end

        idle or dead
      end)

    Enum.each(to_kill, fn {name, %{session: session}} ->
      if backend.supports_sessions?() and is_pid(session) and Process.alive?(session) do
        backend.stop_session(session)
      end
      Logger.info("[SessionPool] Cleaned up idle session for '#{name}'")
    end)

    {:noreply, %{state | sessions: Map.new(to_keep)}}
  end

  # --- Persistent session checkout (ClaudeCode) ---

  defp checkout_persistent(agent_name, session_opts, backend, state) do
    struct_hash = structural_hash(session_opts)

    case Map.get(state.sessions, agent_name) do
      %{session: session, struct_hash: ^struct_hash, task_count: count}
          when count >= @max_tasks_before_reset ->
        Logger.info("[SessionPool] Session for '#{agent_name}' hit #{count} tasks — resetting")
        backend.stop_session(session)
        case create_session(agent_name, session_opts, struct_hash, backend, state) do
          {:ok, session, new_state} -> {:reply, {:ok, session, :new}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | sessions: Map.delete(state.sessions, agent_name)}}
        end

      %{session: session, struct_hash: ^struct_hash} = entry ->
        if is_pid(session) and Process.alive?(session) do
          task_count = (entry[:task_count] || 0) + 1
          Logger.info("[SessionPool] Reusing session for '#{agent_name}' (task ##{task_count})")
          updated = %{entry | last_used: DateTime.utc_now(), task_count: task_count, in_use: true}
          {:reply, {:ok, session, :reused}, %{state | sessions: Map.put(state.sessions, agent_name, updated)}}
        else
          Logger.info("[SessionPool] Session for '#{agent_name}' died, creating new one")
          case create_session(agent_name, session_opts, struct_hash, backend, state) do
            {:ok, session, new_state} -> {:reply, {:ok, session, :new}, new_state}
            {:error, reason} -> {:reply, {:error, reason}, %{state | sessions: Map.delete(state.sessions, agent_name)}}
          end
        end

      %{session: session} ->
        Logger.info("[SessionPool] Structural config changed for '#{agent_name}', replacing session")
        backend.stop_session(session)
        case create_session(agent_name, session_opts, struct_hash, backend, state) do
          {:ok, session, new_state} -> {:reply, {:ok, session, :new}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | sessions: Map.delete(state.sessions, agent_name)}}
        end

      nil ->
        case create_session(agent_name, session_opts, struct_hash, backend, state) do
          {:ok, session, new_state} -> {:reply, {:ok, session, :new}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # --- Stateless session checkout (CursorCLI) ---

  defp checkout_stateless(agent_name, session_opts, backend, state) do
    case backend.start_session(session_opts) do
      {:ok, session} ->
        Logger.info("[SessionPool] Created stateless session for '#{agent_name}' (#{backend.name()})")
        entry = %{
          session: session,
          struct_hash: nil,
          last_used: DateTime.utc_now(),
          task_count: 1,
          in_use: true
        }
        new_state = %{state | sessions: Map.put(state.sessions, agent_name, entry)}
        {:reply, {:ok, session, :new}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Helpers ---

  defp create_session(agent_name, session_opts, struct_hash, backend, state) do
    case backend.start_session(session_opts) do
      {:ok, session} ->
        Logger.info("[SessionPool] Created new session for '#{agent_name}' (#{backend.name()})")
        entry = %{
          session: session,
          struct_hash: struct_hash,
          last_used: DateTime.utc_now(),
          task_count: 1,
          in_use: true
        }
        {:ok, session, %{state | sessions: Map.put(state.sessions, agent_name, entry)}}

      {:error, reason} ->
        Logger.error("[SessionPool] Failed to create session for '#{agent_name}': #{inspect(reason)}")
        {:error, {:session_start_failed, reason}}
    end
  end

  defp structural_hash(session_opts) do
    session_opts
    |> Keyword.take(@structural_keys)
    |> :erlang.phash2()
  end
end

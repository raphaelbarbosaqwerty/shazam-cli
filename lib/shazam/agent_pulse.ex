defmodule Shazam.AgentPulse do
  @moduledoc """
  Tracks agent activity as a sparkline heartbeat.

  Receives events from the stream (text_delta, tool_use, result) and
  maintains a ring buffer of activity per agent. Generates sparkline
  characters (▁▂▃▄▅▆▇█) based on events/second over sliding windows.

  Detects stalls when no events arrive for >30 seconds.
  """

  use GenServer

  @window_seconds 3
  @buffer_windows 10
  @stall_threshold_ms 30_000
  @sparkline_chars ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

  # ── Public API ────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record an event for an agent (called from Provider broadcast)."
  def tick(agent_name, event_type \\ :activity) do
    GenServer.cast(__MODULE__, {:tick, to_string(agent_name), event_type})
  end

  @doc "Get sparkline string for an agent."
  def sparkline(agent_name) do
    GenServer.call(__MODULE__, {:sparkline, to_string(agent_name)})
  catch
    :exit, _ -> ""
  end

  @doc "Get sparkline for all active agents. Returns %{agent_name => sparkline}."
  def all_sparklines do
    GenServer.call(__MODULE__, :all_sparklines)
  catch
    :exit, _ -> %{}
  end

  @doc "Check if an agent appears stalled."
  def stalled?(agent_name) do
    GenServer.call(__MODULE__, {:stalled?, to_string(agent_name)})
  catch
    :exit, _ -> false
  end

  @doc "Mark agent as finished (clear buffer)."
  def clear(agent_name) do
    GenServer.cast(__MODULE__, {:clear, to_string(agent_name)})
  end

  # ── Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    # State: %{agent_name => %{events: [{timestamp_ms, type}], last_tick: ms}}
    {:ok, %{agents: %{}}}
  end

  @impl true
  def handle_cast({:tick, agent_name, event_type}, state) do
    now = System.monotonic_time(:millisecond)
    agent_state = Map.get(state.agents, agent_name, %{events: [], last_tick: now})

    # Append event, keep only last @buffer_windows * @window_seconds seconds
    max_age = @buffer_windows * @window_seconds * 1_000
    events = [{now, event_type} | agent_state.events]
      |> Enum.filter(fn {ts, _} -> now - ts < max_age end)

    agents = Map.put(state.agents, agent_name, %{events: events, last_tick: now})
    {:noreply, %{state | agents: agents}}
  end

  @impl true
  def handle_cast({:clear, agent_name}, state) do
    {:noreply, %{state | agents: Map.delete(state.agents, agent_name)}}
  end

  @impl true
  def handle_call({:sparkline, agent_name}, _from, state) do
    line = case Map.get(state.agents, agent_name) do
      nil -> ""
      agent_state -> build_sparkline(agent_state)
    end
    {:reply, line, state}
  end

  @impl true
  def handle_call(:all_sparklines, _from, state) do
    result = state.agents
      |> Enum.map(fn {name, agent_state} ->
        {name, build_sparkline(agent_state)}
      end)
      |> Enum.into(%{})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:stalled?, agent_name}, _from, state) do
    stalled = case Map.get(state.agents, agent_name) do
      nil -> false
      %{last_tick: last} ->
        System.monotonic_time(:millisecond) - last > @stall_threshold_ms
    end
    {:reply, stalled, state}
  end

  # ── Sparkline Generation ──────────────────────────────

  defp build_sparkline(agent_state) do
    now = System.monotonic_time(:millisecond)
    window_ms = @window_seconds * 1_000

    # Build windows from newest to oldest
    windows = Enum.map(0..(@buffer_windows - 1), fn i ->
      window_start = now - (i + 1) * window_ms
      window_end = now - i * window_ms

      count = Enum.count(agent_state.events, fn {ts, _} ->
        ts >= window_start and ts < window_end
      end)

      count
    end)
    |> Enum.reverse()

    max_count = Enum.max(windows, fn -> 1 end)
    max_count = max(max_count, 1)

    # Check for stall
    stalled = System.monotonic_time(:millisecond) - agent_state.last_tick > @stall_threshold_ms

    chars = Enum.map(windows, fn count ->
      level = round(count / max_count * 7)
      Enum.at(@sparkline_chars, level, "▁")
    end)

    sparkline = Enum.join(chars)

    if stalled do
      sparkline <> " ⚠"
    else
      sparkline
    end
  end
end

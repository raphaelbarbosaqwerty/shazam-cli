defmodule Shazam.API.EventBus do
  @moduledoc """
  PubSub simples para broadcast de eventos para WebSocket clients.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  def unsubscribe do
    GenServer.cast(__MODULE__, {:unsubscribe, self()})
  end

  def broadcast(event) do
    GenServer.cast(__MODULE__, {:broadcast, event})
  end

  @impl true
  def init(_) do
    {:ok, %{subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_cast({:broadcast, event}, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:event, event})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end
end

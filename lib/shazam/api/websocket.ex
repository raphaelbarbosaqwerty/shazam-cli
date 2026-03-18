defmodule Shazam.API.WebSocket do
  @moduledoc "WebSocket handler para eventos em tempo real."

  @behaviour WebSock

  @impl true
  def init(_opts) do
    Shazam.API.EventBus.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"action" => "get_tasks"}} ->
        tasks = Shazam.tasks() |> Enum.map(&serialize_task/1)
        {:push, {:text, Jason.encode!(%{event: "tasks", tasks: tasks})}, state}

      {:ok, %{"action" => "get_statuses", "company" => name}} ->
        statuses = Shazam.statuses(name)
        {:push, {:text, Jason.encode!(%{event: "statuses", agents: statuses})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{error: "unknown_action"})}, state}
    end
  end

  @impl true
  def handle_info({:event, event}, state) do
    {:push, {:text, Jason.encode!(event)}, state}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Shazam.API.EventBus.unsubscribe()
    :ok
  end

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      assigned_to: task.assigned_to,
      result: if(is_binary(task.result), do: task.result, else: inspect(task.result))
    }
  end
end

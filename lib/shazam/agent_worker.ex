defmodule Shazam.AgentWorker do
  @moduledoc """
  Struct que representa a configuração de um agente na organização.
  Usado por Company.build_agent_configs. Execução de tarefas é feita pelo RalphLoop.

  Implements Access behaviour so `agent[:name]` works on structs.
  """

  defstruct [
    :name,
    :role,
    :supervisor,
    :domain,
    :system_prompt,
    :model,
    :fallback_model,
    :provider,
    tools: [],
    skills: [],
    modules: [],
    budget: nil,              # nil = unlimited
    tokens_used: 0,
    heartbeat_interval: 60_000,
    status: :idle,
    context: %{},
    task_history: [],
    company_ref: nil
  ]

  @behaviour Access

  @impl Access
  def fetch(struct, key), do: Map.fetch(struct, key)

  @impl Access
  def get_and_update(struct, key, fun) do
    current = Map.get(struct, key)
    case fun.(current) do
      {get, update} -> {get, Map.put(struct, key, update)}
      :pop -> {current, Map.delete(struct, key)}
    end
  end

  @impl Access
  def pop(struct, key) do
    {Map.get(struct, key), Map.delete(struct, key)}
  end
end

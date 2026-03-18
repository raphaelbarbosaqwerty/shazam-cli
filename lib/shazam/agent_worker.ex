defmodule Shazam.AgentWorker do
  @moduledoc """
  Struct que representa a configuração de um agente na organização.
  Usado por Company.build_agent_configs. Execução de tarefas é feita pelo RalphLoop.
  """

  defstruct [
    :name,
    :role,
    :supervisor,
    :domain,
    :system_prompt,
    :model,
    :fallback_model,
    tools: [],
    skills: [],
    modules: [],
    budget: 100_000,
    tokens_used: 0,
    heartbeat_interval: 60_000,
    status: :idle,
    context: %{},
    task_history: [],
    company_ref: nil
  ]
end

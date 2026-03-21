defmodule Shazam.Company.Builder do
  @moduledoc """
  Handles building AgentWorker structs from config and persisting company data to the Store.
  """

  alias Shazam.Store

  @doc """
  Transforms config agents into a list of `Shazam.AgentWorker` structs.

  Expects a config map with `:name` and `:agents` keys, where each agent
  is a map/struct with keys like `:name`, `:role`, `:supervisor`, etc.
  """
  def build_agent_configs(config) do
    Enum.map(config.agents, fn agent ->
      %Shazam.AgentWorker{
        name: agent.name,
        role: agent.role,
        supervisor: agent[:supervisor],
        domain: agent[:domain],
        budget: agent[:budget],
        heartbeat_interval: agent[:heartbeat_interval] || 60_000,
        tools: agent[:tools] || [],
        skills: agent[:skills] || [],
        modules: agent[:modules] || [],
        system_prompt: agent[:system_prompt],
        model: agent[:model],
        fallback_model: agent[:fallback_model],
        provider: agent[:provider],
        company_ref: config.name
      }
    end)
  end

  @doc """
  Persists a company config (as received at startup) to the Store.
  """
  def save_company(config) do
    data = %{
      "name" => config.name,
      "mission" => config.mission,
      "agents" => Enum.map(config.agents, fn a ->
        %{
          "name" => a.name || a[:name],
          "role" => a.role || a[:role],
          "supervisor" => a[:supervisor],
          "domain" => a[:domain],
          "budget" => a[:budget] || 100_000,
          "heartbeat_interval" => a[:heartbeat_interval] || 60_000,
          "tools" => a[:tools] || [],
          "skills" => a[:skills] || [],
          "modules" => a[:modules] || [],
          "system_prompt" => a[:system_prompt],
          "model" => a[:model],
          "fallback_model" => a[:fallback_model],
          "provider" => a[:provider]
        }
      end)
    }

    Store.save("company:#{config.name}", data)
  end

  @doc """
  Persists the current company GenServer state to the Store.
  Used after in-flight mutations (e.g. update_agents, set_domain_paths).
  """
  def save_company_state(state) do
    data = %{
      "name" => state.name,
      "mission" => state.mission,
      "agents" => Enum.map(state.agents, fn a ->
        %{
          "name" => a.name,
          "role" => a.role,
          "supervisor" => a.supervisor,
          "domain" => a.domain,
          "budget" => a.budget,
          "heartbeat_interval" => a.heartbeat_interval,
          "tools" => a.tools,
          "skills" => a.skills,
          "modules" => a.modules,
          "system_prompt" => a.system_prompt,
          "model" => a.model,
          "fallback_model" => a.fallback_model,
          "provider" => a.provider
        }
      end),
      "domain_config" => state.domain_config
    }

    Store.save("company:#{state.name}", data)
  end

  @doc """
  Builds a list of `Shazam.AgentWorker` structs from raw string-keyed maps
  (e.g. from a web request or deserialized JSON).
  """
  def build_agents_from_raw(agents_raw, company_name) do
    Enum.map(agents_raw, fn a ->
      %Shazam.AgentWorker{
        name: a["name"],
        role: a["role"],
        supervisor: a["supervisor"],
        domain: a["domain"],
        budget: a["budget"],
        heartbeat_interval: a["heartbeat_interval"] || 60_000,
        tools: a["tools"] || [],
        skills: a["skills"] || [],
        modules: a["modules"] || [],
        system_prompt: a["system_prompt"],
        model: a["model"],
        fallback_model: a["fallback_model"],
        provider: a["provider"],
        company_ref: company_name
      }
    end)
  end
end

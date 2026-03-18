defmodule Shazam.ModuleManager do
  @moduledoc """
  Module auto-claim logic extracted from RalphLoop.
  Handles automatically assigning module ownership to agents based on touched files.
  """

  require Logger

  alias Shazam.TaskScheduler

  @doc "Auto-claim orphan modules based on files touched by an agent."
  def auto_claim_modules(_company, _agent_name, []), do: :ok
  def auto_claim_modules(nil, _agent_name, _files), do: :ok
  def auto_claim_modules(company_name, agent_name, touched_files) do
    workspace = Application.get_env(:shazam, :workspace, nil)
    unless workspace, do: throw(:no_workspace)

    # Extract relative directories from touched files (first significant level)
    new_dirs =
      touched_files
      |> Enum.map(fn file_path ->
        relative = Path.relative_to(file_path, workspace)
        # Get the module directory (e.g., "lib/auth/handler.ex" → "lib/auth")
        parts = Path.split(relative)
        if length(parts) >= 2, do: Path.join(Enum.take(parts, 2)), else: nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if new_dirs == [] do
      :ok
    else
      try do
        agents = Shazam.Company.get_agents(company_name)
        agent = Enum.find(agents, &(&1.name == agent_name))
        unless agent, do: throw(:agent_not_found)

        current_paths = TaskScheduler.extract_module_paths(agent.modules)

        # Collect all modules from all agents (to know who owns what)
        all_owned_paths =
          agents
          |> Enum.flat_map(fn a -> TaskScheduler.extract_module_paths(a.modules) end)
          |> MapSet.new()

        # Filter directories that the agent doesn't already own
        dirs_to_add =
          new_dirs
          |> Enum.reject(fn dir -> dir in current_paths end)
          # Only auto-claim if nobody owns it (orphan module)
          |> Enum.reject(fn dir -> MapSet.member?(all_owned_paths, dir) end)

        if dirs_to_add != [] do
          new_modules =
            dirs_to_add
            |> Enum.map(fn dir ->
              %{"name" => Path.basename(dir), "path" => dir}
            end)

          updated_agents =
            Enum.map(agents, fn a ->
              mods = if a.name == agent_name do
                existing_mods = Enum.map(a.modules || [], fn m ->
                  %{"name" => m["name"] || m[:name], "path" => m["path"] || m[:path]}
                end)
                existing_mods ++ new_modules
              else
                Enum.map(a.modules || [], fn m ->
                  %{"name" => m["name"] || m[:name], "path" => m["path"] || m[:path]}
                end)
              end

              agent_to_map(a, mods)
            end)

          Shazam.Company.update_agents(company_name, updated_agents)

          Logger.info("[RalphLoop] Agent '#{agent_name}' auto-claimed modules: #{inspect(dirs_to_add)}")

          Shazam.API.EventBus.broadcast(%{
            event: "modules_claimed",
            agent: agent_name,
            modules: dirs_to_add
          })
        end
      rescue
        _ -> :ok
      catch
        _ -> :ok
      end
    end
  end

  # Converts an agent struct to a string-keyed map for Company.update_agents
  defp agent_to_map(a, modules) do
    mods = modules || Enum.map(a.modules || [], fn m ->
      %{"name" => m["name"] || m[:name], "path" => m["path"] || m[:path]}
    end)

    %{
      "name" => a.name, "role" => a.role, "supervisor" => a.supervisor,
      "domain" => a.domain, "budget" => a.budget,
      "heartbeat_interval" => a.heartbeat_interval,
      "tools" => a.tools, "skills" => a.skills || [],
      "modules" => mods,
      "system_prompt" => a.system_prompt, "model" => a.model,
      "fallback_model" => a.fallback_model
    }
  end
end

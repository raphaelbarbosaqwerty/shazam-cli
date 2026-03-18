defmodule Mix.Tasks.Shazam.Apply do
  @moduledoc "Apply shazam.yaml config to a running system."
  @shortdoc "Reconcile running state with shazam.yaml"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers, YamlParser}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [file: :string], aliases: [f: :file])

    yaml_file = opts[:file] || default_yaml()

    config = case YamlParser.parse(yaml_file) do
      {:ok, config} -> config
      {:error, reason} ->
        Formatter.error(reason)
        System.halt(1)
    end

    Helpers.ensure_app()

    company_name = config.name

    # Check if company exists
    running = Helpers.running_companies()

    if company_name in running do
      # Update existing company
      Formatter.info("Updating '#{company_name}'...")

      # Get current agents for diff
      try do
        current = Shazam.Company.get_agents_full(company_name)
        current_names = MapSet.new(Enum.map(current, & &1["name"]))
        new_names = MapSet.new(Enum.map(config.agents, & &1.name))

        added = MapSet.difference(new_names, current_names) |> MapSet.to_list()
        removed = MapSet.difference(current_names, new_names) |> MapSet.to_list()
        kept = MapSet.intersection(current_names, new_names) |> MapSet.size()

        # Build updated agents list in the format update_agents expects
        agents_raw = Enum.map(config.agents, fn a ->
          %{
            "name" => a.name,
            "role" => a.role,
            "supervisor" => a[:supervisor],
            "domain" => a[:domain],
            "budget" => a[:budget] || 100_000,
            "model" => a[:model],
            "tools" => a[:tools] || [],
            "skills" => a[:skills] || [],
            "modules" => a[:modules] || [],
            "system_prompt" => a[:system_prompt]
          }
        end)

        Shazam.Company.update_agents(company_name, agents_raw)

        if added != [], do: Formatter.success("Added: #{Enum.join(added, ", ")}")
        if removed != [], do: Formatter.warning("Removed: #{Enum.join(removed, ", ")}")
        Formatter.info("#{kept} agent(s) updated, #{length(config.agents)} total")
      rescue
        e ->
          Formatter.error("Failed to update: #{inspect(e)}")
      end
    else
      # Create new company
      Formatter.info("Creating '#{company_name}'...")

      company_config = %{
        name: company_name,
        mission: config.mission,
        agents: config.agents,
        domain_config: config[:domain_config] || %{}
      }

      case Shazam.start_company(company_config) do
        {:ok, _} ->
          Formatter.success("Company '#{company_name}' created with #{length(config.agents)} agent(s)")
        {:error, reason} ->
          Formatter.error("Failed: #{inspect(reason)}")
      end
    end
  end

  defp default_yaml do
    if File.exists?(".shazam/shazam.yaml"), do: ".shazam/shazam.yaml", else: "shazam.yaml"
  end
end

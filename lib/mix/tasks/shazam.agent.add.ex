defmodule Mix.Tasks.Shazam.Agent.Add do
  @moduledoc "Add an agent to a running Shazam company."
  @shortdoc "Add a new agent"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args,
      switches: [
        name: :string,
        role: :string,
        supervisor: :string,
        domain: :string,
        budget: :integer,
        model: :string,
        company: :string,
        preset: :string
      ],
      aliases: [n: :name, r: :role, s: :supervisor, d: :domain, b: :budget, m: :model, c: :company]
    )

    Helpers.ensure_app()

    company = Helpers.find_company(opts)

    unless company do
      Formatter.error("No company running. Start with 'mix shazam.start'")
      System.halt(1)
    end

    # Name can be positional or --name
    agent_name = opts[:name] || List.first(positional)

    unless agent_name do
      Formatter.error("Usage: mix shazam.agent.add AGENT_NAME --role 'Role' [--supervisor pm]")
      System.halt(1)
    end

    # Build agent config
    agent = if opts[:preset] do
      case Shazam.AgentPresets.build(opts[:preset], %{}) do
        {:ok, preset_config} ->
          Map.merge(preset_config, %{
            "name" => agent_name,
            "role" => opts[:role] || preset_config["role"],
            "supervisor" => opts[:supervisor],
            "domain" => opts[:domain],
            "budget" => opts[:budget] || preset_config["budget"] || 100_000,
            "model" => opts[:model] || preset_config["model"]
          })
        {:error, _} ->
          Formatter.error("Unknown preset '#{opts[:preset]}'")
          System.halt(1)
      end
    else
      %{
        "name" => agent_name,
        "role" => opts[:role] || "Agent",
        "supervisor" => opts[:supervisor],
        "domain" => opts[:domain],
        "budget" => opts[:budget] || 100_000,
        "model" => opts[:model],
        "tools" => ["Read", "Edit", "Write", "Bash", "Grep", "Glob"],
        "skills" => [],
        "modules" => []
      }
    end

    # Get current agents and append
    try do
      current = Shazam.Company.get_agents_full(company)
      existing_names = Enum.map(current, & &1["name"])

      if agent_name in existing_names do
        Formatter.error("Agent '#{agent_name}' already exists in '#{company}'")
        System.halt(1)
      end

      updated = current ++ [agent]
      Shazam.Company.update_agents(company, updated)

      Formatter.success("Agent '#{agent_name}' added to '#{company}'")
      Formatter.info("Role: #{agent["role"]}")
      if agent["supervisor"], do: Formatter.info("Reports to: #{agent["supervisor"]}")
      if agent["domain"], do: Formatter.info("Domain: #{agent["domain"]}")
    rescue
      e ->
        Formatter.error("Failed: #{inspect(e)}")
    end
  end
end

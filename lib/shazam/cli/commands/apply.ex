defmodule Shazam.CLI.Commands.Apply do
  @moduledoc """
  Implements `shazam apply` — reads `shazam.yaml` and pushes the agent
  configuration to a running company via the HTTP API.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [file: :string, port: :integer],
        aliases: [f: :file, p: :port]
      )

    port = opts[:port] || @port
    yaml_file = opts[:file] || Shared.default_yaml()

    config =
      case Shazam.CLI.YamlParser.parse(yaml_file) do
        {:ok, c} ->
          c

        {:error, reason} ->
          Formatter.error(reason)
          System.halt(1)
      end

    Formatter.info("Applying #{yaml_file} → #{config.name}...")

    # Check if company exists
    case HttpClient.get(port, "/api/companies") do
      {:ok, %{"companies" => companies}} ->
        names = Enum.map(companies, & &1["name"])

        if config.name in names do
          # Update agents
          agents_raw =
            Enum.map(config.agents, fn a ->
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

          case HttpClient.put(port, "/api/companies/#{URI.encode(config.name)}/agents", %{agents: agents_raw}) do
            {:ok, _} ->
              Formatter.success("Updated '#{config.name}' — #{length(config.agents)} agent(s)")

            {:error, reason} ->
              Formatter.error("Failed to update: #{reason}")
          end
        else
          Formatter.info("Company '#{config.name}' not running — use 'shazam start' to create it")
        end

      {:error, reason} ->
        Formatter.error("Cannot reach server: #{reason}")
    end
  end
end

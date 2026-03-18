defmodule Shazam.CLI.Commands.AgentAdd do
  @moduledoc """
  Implements `shazam agent add <name>` — adds a new agent to a running
  company via the HTTP API.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          role: :string,
          supervisor: :string,
          domain: :string,
          budget: :integer,
          model: :string,
          company: :string,
          port: :integer
        ],
        aliases: [r: :role, s: :supervisor, d: :domain, b: :budget, m: :model, c: :company, p: :port]
      )

    port = opts[:port] || @port
    agent_name = List.first(positional)

    unless agent_name do
      Formatter.error("Usage: shazam agent add NAME --role 'Role' [--supervisor pm]")
      System.halt(1)
    end

    company = opts[:company] || Shared.yaml_company()

    unless company do
      Formatter.error("No company. Use --company NAME or shazam.yaml")
      System.halt(1)
    end

    body = %{
      name: agent_name,
      role: opts[:role] || "Agent",
      supervisor: opts[:supervisor],
      domain: opts[:domain],
      budget: opts[:budget] || 100_000,
      model: opts[:model],
      tools: ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]
    }

    case HttpClient.post(port, "/api/companies/#{URI.encode(company)}/agents/add", body) do
      {:ok, _} ->
        Formatter.success("Agent '#{agent_name}' added to '#{company}'")
        Formatter.info("Role: #{body.role}")
        if opts[:supervisor], do: Formatter.info("Reports to: #{opts[:supervisor]}")

      {:error, reason} ->
        Formatter.error("Failed: #{reason}")
    end
  end
end

defmodule Shazam.CLI.Commands.Stop do
  @moduledoc """
  Implements `shazam stop` — stops a single company or all companies
  via the HTTP API.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [company: :string, all: :boolean, port: :integer],
        aliases: [c: :company, p: :port]
      )

    port = opts[:port] || @port
    company = opts[:company] || Shared.yaml_company()

    if opts[:all] do
      case HttpClient.get(port, "/api/companies") do
        {:ok, %{"companies" => companies}} ->
          Enum.each(companies, fn c ->
            HttpClient.post(port, "/api/companies/#{URI.encode(c["name"])}/stop", %{})
            Formatter.success("Stopped '#{c["name"]}'")
          end)

        {:error, reason} ->
          Formatter.error("Cannot reach server: #{reason}")
      end
    else
      unless company do
        Formatter.error("Specify --company NAME or have shazam.yaml in CWD")
        System.halt(1)
      end

      case HttpClient.post(port, "/api/companies/#{URI.encode(company)}/stop", %{}) do
        {:ok, _} -> Formatter.success("Company '#{company}' stopped")
        {:error, reason} -> Formatter.error("Failed: #{reason}")
      end
    end
  end
end

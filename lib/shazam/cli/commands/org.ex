defmodule Shazam.CLI.Commands.Org do
  @moduledoc """
  Implements `shazam org` — fetches and displays the company org chart
  as a tree.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string, port: :integer])
    port = opts[:port] || @port
    company = opts[:company] || Shared.yaml_company()

    unless company do
      Formatter.error("No company. Use --company NAME or shazam.yaml")
      System.halt(1)
    end

    Formatter.header("Org Chart — #{company}")
    IO.puts("")

    case HttpClient.get(port, "/api/companies/#{URI.encode(company)}/org-chart") do
      {:ok, %{"org_chart" => chart}} when is_list(chart) ->
        nodes = normalize_chart(chart)
        Formatter.tree(nodes)

      {:ok, _} ->
        Formatter.dim("No org chart data")

      {:error, reason} ->
        Formatter.error("Failed: #{reason}")
    end

    IO.puts("")
  end

  # ── private ───────────────────────────────────────────────

  defp normalize_chart(nodes) when is_list(nodes) do
    Enum.map(nodes, fn n ->
      %{
        name: n["name"] || n[:name],
        role: n["role"] || n[:role] || "Agent",
        domain: n["domain"] || n[:domain],
        status: n["status"] || n[:status],
        subordinates: normalize_chart(n["subordinates"] || n[:subordinates] || [])
      }
    end)
  end
end

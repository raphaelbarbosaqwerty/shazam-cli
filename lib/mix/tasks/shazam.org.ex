defmodule Mix.Tasks.Shazam.Org do
  @moduledoc "Display the organization chart of a Shazam company."
  @shortdoc "Show agent hierarchy tree"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string], aliases: [c: :company])

    Helpers.ensure_app()

    company = Helpers.find_company(opts)

    unless company do
      Formatter.error("No company running. Start with 'mix shazam.start'")
      System.halt(1)
    end

    Formatter.header("Org Chart — #{company}")

    try do
      chart = Shazam.org_chart(company)
      IO.puts("")

      if is_list(chart) && chart != [] do
        nodes = normalize_chart(chart)
        Formatter.tree(nodes)
      else
        Formatter.dim("No agents configured")
      end
    rescue
      e ->
        Formatter.error("Failed: #{inspect(e)}")
    end

    IO.puts("")
  end

  defp normalize_chart(nodes) when is_list(nodes) do
    Enum.map(nodes, fn node ->
      %{
        name: node["name"] || node[:name],
        role: node["role"] || node[:role] || "Agent",
        domain: node["domain"] || node[:domain],
        status: node["status"] || node[:status],
        subordinates: normalize_chart(node["subordinates"] || node[:subordinates] || [])
      }
    end)
  end
end

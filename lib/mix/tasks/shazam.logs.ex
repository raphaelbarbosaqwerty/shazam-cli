defmodule Mix.Tasks.Shazam.Logs do
  @moduledoc "Stream real-time agent events from Shazam."
  @shortdoc "Stream live agent output and events"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args,
      switches: [company: :string, domain: :string],
      aliases: [c: :company, d: :domain]
    )

    Helpers.ensure_app()

    filter_agent = List.first(positional)
    filter_domain = opts[:domain]

    company = Helpers.find_company(opts)

    Formatter.header("Live Logs#{if company, do: " — #{company}", else: ""}")

    if filter_agent, do: Formatter.dim("Filtering: agent=#{filter_agent}")
    if filter_domain, do: Formatter.dim("Filtering: domain=#{filter_domain}")

    IO.puts("")

    # Subscribe to EventBus
    Shazam.API.EventBus.subscribe()

    # Enter receive loop
    loop(filter_agent, filter_domain, company)
  end

  defp loop(filter_agent, filter_domain, company) do
    receive do
      {:event, event} when is_map(event) ->
        if matches_filter?(event, filter_agent, filter_domain, company) do
          Formatter.log_event(event)
        end
        loop(filter_agent, filter_domain, company)

      _ ->
        loop(filter_agent, filter_domain, company)
    end
  end

  defp matches_filter?(event, agent, domain, company) do
    agent_match = is_nil(agent) || get_field(event, "agent") == agent ||
                  get_field(event, "assigned_to") == agent
    domain_match = is_nil(domain) || get_field(event, "domain") == domain
    company_match = is_nil(company) || get_field(event, "company") == company

    agent_match && domain_match && company_match
  end

  defp get_field(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end

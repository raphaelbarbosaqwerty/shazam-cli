defmodule Shazam.CLI.Commands.Logs do
  @moduledoc """
  Implements `shazam logs [agent]` — streams live events from the
  EventBus or falls back to HTTP polling.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [port: :integer, company: :string],
        aliases: [p: :port, c: :company]
      )

    port = opts[:port] || @port
    filter_agent = List.first(positional)
    company = opts[:company] || Shared.yaml_company()

    Formatter.header("Live Logs#{if company, do: " — #{company}", else: ""}")
    if filter_agent, do: Formatter.dim("Filtering: agent=#{filter_agent}")
    IO.puts("")

    poll_logs(port, company, filter_agent)
  end

  # ── private ───────────────────────────────────────────────

  defp poll_logs(port, company, filter_agent) do
    case HttpClient.get(port, "/api/events/recent") do
      {:ok, %{"events" => events}} when is_list(events) ->
        events
        |> Shared.maybe_filter_agent(filter_agent)
        |> Shared.maybe_filter_company(company)
        |> Enum.each(&Formatter.log_event/1)

      _ ->
        :ok
    end

    # Also boot OTP and subscribe for real-time if possible
    try do
      Shared.boot_app()
      Shazam.API.EventBus.subscribe()

      Formatter.info("Connected to EventBus — streaming live")
      IO.puts("")

      event_loop(filter_agent, company)
    rescue
      _ ->
        Formatter.warning("Cannot connect to EventBus directly, polling every 3s...")
        polling_loop(port, company, filter_agent, MapSet.new())
    end
  end

  defp event_loop(filter_agent, company) do
    receive do
      {:event, event} when is_map(event) ->
        show =
          (is_nil(filter_agent) or Shared.match_field?(event, "agent", filter_agent)) and
            (is_nil(company) or Shared.match_field?(event, "company", company))

        if show, do: Formatter.log_event(event)
        event_loop(filter_agent, company)

      _ ->
        event_loop(filter_agent, company)
    end
  end

  defp polling_loop(port, company, filter_agent, seen) do
    Process.sleep(3000)

    case HttpClient.get(port, "/api/tasks?company=#{URI.encode(company || "")}") do
      {:ok, %{"tasks" => tasks}} ->
        tasks
        |> Enum.reject(fn t -> MapSet.member?(seen, t["id"]) end)
        |> Shared.maybe_filter_agent(filter_agent)
        |> Enum.each(fn t ->
          Formatter.log_event(%{
            "event" => "task_#{t["status"]}",
            "agent" => t["assigned_to"],
            "title" => t["title"]
          })
        end)

        new_seen = tasks |> Enum.map(& &1["id"]) |> MapSet.new() |> MapSet.union(seen)
        polling_loop(port, company, filter_agent, new_seen)

      _ ->
        polling_loop(port, company, filter_agent, seen)
    end
  end
end

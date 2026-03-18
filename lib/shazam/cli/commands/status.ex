defmodule Shazam.CLI.Commands.Status do
  @moduledoc """
  Implements `shazam status` — queries the running server and displays
  company info, agent roster, and task counts.
  """

  alias Shazam.CLI.{Formatter, HttpClient}

  @port 4040

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [company: :string, port: :integer])
    port = opts[:port] || @port

    case HttpClient.get(port, "/api/companies") do
      {:ok, %{"companies" => companies}} ->
        if companies == [] do
          Formatter.warning("No companies running")
          Formatter.dim("Run 'shazam start' to boot from shazam.yaml")
        else
          Enum.each(companies, fn c ->
            name = c["name"]

            active =
              if c["active"],
                do: [IO.ANSI.green(), "● running"],
                else: [IO.ANSI.yellow(), "○ stopped"]

            Formatter.header(name)
            IO.puts(["  Status: ", active, IO.ANSI.reset()])

            # Get agent details
            case HttpClient.get(port, "/api/companies/#{URI.encode(name)}/agents") do
              {:ok, %{"agents" => agents}} when is_list(agents) ->
                headers = ["Agent", "Role", "Supervisor", "Domain"]

                rows =
                  Enum.map(agents, fn a ->
                    [a["name"] || "?", a["role"] || "?", a["supervisor"] || "—", a["domain"] || "—"]
                  end)

                Formatter.table(headers, rows)

              _ ->
                :ok
            end

            # Task counts
            case HttpClient.get(port, "/api/tasks?company=#{URI.encode(name)}") do
              {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
                by_status = Enum.group_by(tasks, & &1["status"])

                counts =
                  ["pending", "running", "completed", "failed"]
                  |> Enum.map(fn s -> "#{s}: #{length(by_status[s] || [])}" end)
                  |> Enum.join("  ")

                Formatter.info("Tasks — #{counts}")

              _ ->
                :ok
            end

            IO.puts("")
          end)
        end

      {:error, reason} ->
        Formatter.error("Cannot reach Shazam on port #{port}")
        Formatter.dim("#{reason}")
        Formatter.dim("Is the server running? Start with 'shazam start'")
    end
  end
end

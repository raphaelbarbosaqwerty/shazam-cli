defmodule Shazam.CLI.Commands.Task do
  @moduledoc """
  Implements `shazam task "title"` — creates a new task via the HTTP API.
  """

  alias Shazam.CLI.{Formatter, HttpClient, Shared}

  @port 4040

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [to: :string, company: :string, port: :integer],
        aliases: [t: :to, c: :company, p: :port]
      )

    title = Enum.join(positional, " ")
    port = opts[:port] || @port

    if title == "" do
      Formatter.error("Usage: shazam task \"Task description\" [--to agent_name]")
      System.halt(1)
    end

    company = opts[:company] || Shared.yaml_company()

    unless company do
      Formatter.error("No company found. Use --company NAME or have shazam.yaml")
      System.halt(1)
    end

    body = %{title: title, description: title}
    body = if opts[:to], do: Map.put(body, :assigned_to, opts[:to]), else: body

    case HttpClient.post(port, "/api/companies/#{URI.encode(company)}/tasks", body) do
      {:ok, resp} ->
        task_id = resp["task_id"] || resp["id"] || "?"
        Formatter.success("Task ##{task_id} created")
        Formatter.info("\"#{title}\"#{if opts[:to], do: " → #{opts[:to]}", else: ""}")

      {:error, reason} ->
        Formatter.error("Failed: #{reason}")
    end
  end
end

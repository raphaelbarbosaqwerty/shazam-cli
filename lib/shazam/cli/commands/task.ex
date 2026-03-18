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

    path = "/api/companies/#{URI.encode(company)}/tasks"

    case HttpClient.post(port, path, body) do
      {:ok, resp} ->
        task_id = resp["task_id"] || resp["id"] || "?"
        Formatter.success("Task ##{task_id} created")
        Formatter.info("\"#{title}\"#{if opts[:to], do: " → #{opts[:to]}", else: ""}")

      {:error, msg} ->
        cond do
          is_binary(msg) and String.contains?(msg, "Cannot connect") ->
            Formatter.error("Servidor não está rodando em localhost:#{port}.")
            Formatter.dim("  Suba com: shazam start  (na pasta do projeto, com o mesmo shazam.yaml)")
            Formatter.dim("  Com cursor_cli, as tarefas rodam via `agent` depois que o servidor está ativo.")

          match?("HTTP 503: " <> _, msg) ->
            rest = String.replace_prefix(msg, "HTTP 503: ", "")
            Formatter.error("Não foi possível criar a tarefa (empresa parada).")
            case Jason.decode(rest) do
              {:ok, %{"error" => err_msg}} -> Formatter.dim("  #{err_msg}")
              _ -> Formatter.dim("  #{rest}")
            end

          true ->
            Formatter.error("Failed: #{msg}")
        end
    end
  end
end

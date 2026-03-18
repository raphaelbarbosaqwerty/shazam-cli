defmodule Mix.Tasks.Shazam.Stop do
  @moduledoc "Stop a running Shazam company."
  @shortdoc "Stop company (via HTTP to running instance)"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [company: :string, all: :boolean, port: :integer],
      aliases: [c: :company, p: :port]
    )

    port = opts[:port] || 4040

    if opts[:all] do
      stop_all(port)
    else
      company = opts[:company] || Helpers.from_yaml()

      unless company do
        Formatter.error("No company specified. Use --company NAME or have a shazam.yaml")
        System.halt(1)
      end

      stop_company(company, port)
    end
  end

  defp stop_company(name, port) do
    :inets.start()
    :ssl.start()
    url = ~c"http://127.0.0.1:#{port}/api/companies/#{name}/stop"

    case :httpc.request(:post, {url, [], ~c"application/json", ~c"{}"}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        Formatter.success("Company '#{name}' stopped")
      {:ok, {{_, code, _}, _, body}} ->
        Formatter.error("Failed (#{code}): #{body}")
      {:error, reason} ->
        Formatter.error("Cannot reach server on port #{port}: #{inspect(reason)}")
        Formatter.dim("Is Shazam running? Start with 'mix shazam.start'")
    end
  end

  defp stop_all(port) do
    :inets.start()
    :ssl.start()
    url = ~c"http://127.0.0.1:#{port}/api/companies"

    case :httpc.request(:get, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"companies" => companies}} ->
            Enum.each(companies, fn c ->
              stop_company(c["name"], port)
            end)
          _ ->
            Formatter.error("Unexpected response")
        end
      {:error, reason} ->
        Formatter.error("Cannot reach server: #{inspect(reason)}")
    end
  end
end

defmodule Shazam.CLI.Helpers do
  @moduledoc "Shared helpers for CLI Mix tasks."

  alias Shazam.CLI.Formatter

  @doc "Finds the active company name from args, yaml, or first running."
  def find_company(opts) do
    opts[:company] || from_yaml() || first_running()
  end

  @doc "Reads company name from shazam.yaml in CWD."
  def from_yaml do
    case Shazam.CLI.YamlParser.parse() do
      {:ok, config} -> config.name
      _ -> nil
    end
  end

  @doc "Returns the first running company from Registry."
  def first_running do
    case Registry.select(Shazam.CompanyRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
      [name | _] -> name
      [] -> nil
    end
  end

  @doc "Lists all running company names."
  def running_companies do
    Registry.select(Shazam.CompanyRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Ensures the OTP app is started."
  def ensure_app do
    Mix.Task.run("app.start")
  end

  @doc "Tries HTTP fallback if OTP app is already running elsewhere."
  def try_http(method, path) do
    :inets.start()
    :ssl.start()
    port = Application.get_env(:shazam, :port, 4040)
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case method do
      :get ->
        :httpc.request(:get, {url, []}, [{:timeout, 5000}], [])
      :delete ->
        :httpc.request(:delete, {url, []}, [{:timeout, 5000}], [])
    end
  end

  @doc "Prompts for user input with a default value."
  def prompt(label, default \\ nil) do
    suffix = if default, do: " [#{default}]", else: ""
    answer = Mix.shell().prompt("  #{label}#{suffix}: ") |> String.trim()
    if answer == "" && default, do: to_string(default), else: answer
  end

  @doc "Prompts for yes/no with default."
  def confirm?(label, default \\ true) do
    suffix = if default, do: "[Y/n]", else: "[y/N]"
    answer = Mix.shell().prompt("  #{label} #{suffix}: ") |> String.trim() |> String.downcase()
    case answer do
      "" -> default
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  @doc "Aborts with an error message."
  def abort(msg) do
    Formatter.error(msg)
    System.halt(1)
  end
end

defmodule Shazam.CLI.Shared do
  @moduledoc """
  Shared helpers used by multiple CLI command modules.
  """

  @default_config ".shazam/shazam.yaml"

  @doc "Returns the path to the default YAML config file."
  def default_yaml do
    if File.exists?(@default_config), do: @default_config, else: "shazam.yaml"
  end

  @doc "Reads the company name from the default YAML config, or nil."
  def yaml_company do
    case Shazam.CLI.YamlParser.parse(default_yaml()) do
      {:ok, config} -> config.name
      _ -> nil
    end
  end

  @doc "Ensures the OTP application is fully started."
  def boot_app do
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:shazam)
  end

  @doc "Checks whether `event[field]` (string or atom key) equals `value`."
  def match_field?(event, field, value) do
    (Map.get(event, field) || Map.get(event, String.to_atom(field))) == value
  end

  @doc "Filters items by agent name, no-op when filter is nil."
  def maybe_filter_agent(items, nil), do: items

  def maybe_filter_agent(items, agent) do
    Enum.filter(items, fn i ->
      (i["agent"] || i["assigned_to"]) == agent
    end)
  end

  @doc "Filters items by company name, no-op when filter is nil."
  def maybe_filter_company(items, nil), do: items

  def maybe_filter_company(items, company) do
    Enum.filter(items, fn i -> i["company"] == company end)
  end
end

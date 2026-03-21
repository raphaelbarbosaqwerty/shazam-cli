defmodule Shazam.Store do
  @moduledoc """
  JSON file persistence layer.
  Stores data as JSON files in `~/.shazam/`.
  """

  require Logger

  @data_dir Path.expand("~/.shazam")

  def data_dir, do: @data_dir

  @doc "Initializes persistence directory."
  def init do
    File.mkdir_p!(@data_dir)
    :ok
  end

  @doc "Saves data under the given key."
  def save(key, data) do
    path = key_to_path(key)
    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
    :ok
  rescue
    e ->
      Logger.error("[Store] Failed to save #{key}: #{inspect(e)}")
      {:error, e}
  end

  @doc "Loads data for the given key. Returns {:ok, data} or {:error, :not_found}."
  def load(key) do
    path = key_to_path(key)

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :not_found}
        end
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Store] Failed to load #{key}: #{inspect(e)}")
      {:error, e}
  end

  @doc "Lists all keys matching a prefix."
  def list_keys(prefix) do
    safe_prefix = prefix |> to_string() |> String.replace(~r/[^a-zA-Z0-9_\-:]/, "_")

    case File.ls(@data_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.starts_with?(f, safe_prefix) and String.ends_with?(f, ".json") end)
        |> Enum.map(fn f -> String.trim_trailing(f, ".json") end)
      {:error, _} -> []
    end
  rescue
    e ->
      Logger.warning("[Store] Failed to list keys with prefix #{prefix}: #{inspect(e)}")
      []
  end

  @doc "Removes data for the given key."
  def delete(key) do
    path = key_to_path(key)
    File.rm(path)
    :ok
  rescue
    e ->
      Logger.error("[Store] Failed to delete #{key}: #{inspect(e)}")
      {:error, e}
  end

  # ── Private ──────────────────────────────────────────────

  defp key_to_path(key) do
    safe_key = key |> to_string() |> String.replace(~r/[^a-zA-Z0-9_\-:]/, "_")
    Path.join(@data_dir, "#{safe_key}.json")
  end
end

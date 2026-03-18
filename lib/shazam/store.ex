defmodule Shazam.Store do
  @moduledoc """
  Persistence layer with automatic backend selection:
  - SQLite (via Shazam.Repo) when the NIF is available
  - JSON files as fallback (e.g., escript without NIF)

  Provides the same public API: init/0, save/2, load/1, delete/1.
  """

  require Logger

  @data_dir Path.expand("~/.shazam")

  def data_dir, do: @data_dir

  @doc "Initializes persistence. Tries SQLite, falls back to JSON files."
  def init do
    File.mkdir_p!(@data_dir)

    if sqlite_available?() do
      try do
        Shazam.Repo.init()
        Application.put_env(:shazam, :store_backend, :sqlite)
        :ok
      rescue
        _e ->
          Application.put_env(:shazam, :store_backend, :json)
          :ok
      end
    else
      Application.put_env(:shazam, :store_backend, :json)
      :ok
    end
  end

  @doc "Saves data under the given key."
  def save(key, data) do
    case backend() do
      :sqlite -> save_sqlite(key, data)
      :json -> save_json(key, data)
    end
  rescue
    e ->
      Logger.error("[Store] Failed to save #{key}: #{inspect(e)}")
      {:error, e}
  end

  @doc "Loads data for the given key. Returns {:ok, data} or {:error, :not_found}."
  def load(key) do
    case backend() do
      :sqlite -> load_sqlite(key)
      :json -> load_json(key)
    end
  rescue
    e ->
      Logger.warning("[Store] Failed to load #{key}: #{inspect(e)}")
      {:error, e}
  end

  @doc "Lists all keys matching a prefix."
  def list_keys(prefix) do
    case backend() do
      :sqlite -> list_keys_sqlite(prefix)
      :json -> list_keys_json(prefix)
    end
  rescue
    e ->
      Logger.warning("[Store] Failed to list keys with prefix #{prefix}: #{inspect(e)}")
      []
  end

  @doc "Removes data for the given key."
  def delete(key) do
    case backend() do
      :sqlite -> delete_sqlite(key)
      :json -> delete_json(key)
    end
  rescue
    e ->
      Logger.error("[Store] Failed to delete #{key}: #{inspect(e)}")
      {:error, e}
  end

  # ── Backend selection ──────────────────────────────────────

  defp backend do
    Application.get_env(:shazam, :store_backend, :json)
  end

  defp sqlite_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3) and
      function_exported?(Exqlite.Sqlite3, :open, 1)
  end

  # ── SQLite backend ─────────────────────────────────────────

  defp save_sqlite(key, data) do
    Shazam.Repo.with_conn(fn conn ->
      Shazam.Repo.kv_put(conn, to_string(key), data)
    end)
  end

  defp load_sqlite(key) do
    Shazam.Repo.with_conn(fn conn ->
      Shazam.Repo.kv_get(conn, to_string(key))
    end)
  end

  defp list_keys_sqlite(prefix) do
    Shazam.Repo.with_conn(fn conn ->
      Shazam.Repo.kv_list_keys(conn, prefix)
    end)
  end

  defp delete_sqlite(key) do
    Shazam.Repo.with_conn(fn conn ->
      Shazam.Repo.kv_delete(conn, to_string(key))
    end)
  end

  # ── JSON file backend ──────────────────────────────────────

  defp key_to_path(key) do
    safe_key = key |> to_string() |> String.replace(~r/[^a-zA-Z0-9_\-:]/, "_")
    Path.join(@data_dir, "#{safe_key}.json")
  end

  defp save_json(key, data) do
    path = key_to_path(key)
    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
    :ok
  end

  defp load_json(key) do
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
  end

  defp list_keys_json(prefix) do
    safe_prefix = prefix |> to_string() |> String.replace(~r/[^a-zA-Z0-9_\-:]/, "_")

    case File.ls(@data_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.starts_with?(f, safe_prefix) and String.ends_with?(f, ".json") end)
        |> Enum.map(fn f -> String.trim_trailing(f, ".json") end)
      {:error, _} -> []
    end
  end

  defp delete_json(key) do
    path = key_to_path(key)
    File.rm(path)
    :ok
  end
end

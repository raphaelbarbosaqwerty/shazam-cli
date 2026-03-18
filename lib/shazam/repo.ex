defmodule Shazam.Repo do
  @moduledoc """
  SQLite persistence layer using Exqlite.
  Manages the database file, schema migrations, and provides
  query helpers for all Shazam tables.
  """

  require Logger

  @data_dir Path.expand("~/.shazam")
  @db_path Path.join(@data_dir, "shazam.db")

  # Current schema version — bump this when adding migrations
  @schema_version 1

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  def data_dir, do: @data_dir
  def db_path, do: @db_path

  @doc "Opens the database, runs migrations, and returns :ok."
  def init do
    File.mkdir_p!(@data_dir)

    case Exqlite.Sqlite3.open(@db_path) do
      {:ok, conn} ->
        # Enable WAL mode for better concurrent read performance
        :ok = exec(conn, "PRAGMA journal_mode=WAL")
        :ok = exec(conn, "PRAGMA foreign_keys=ON")

        run_migrations(conn)

        Exqlite.Sqlite3.close(conn)
        Logger.info("[Repo] Database initialized at #{@db_path} (schema v#{@schema_version})")
        :ok

      {:error, reason} ->
        Logger.warning("[Repo] Cannot open SQLite: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Executes a callback with a fresh connection. Returns the callback result."
  def with_conn(fun) do
    {:ok, conn} = Exqlite.Sqlite3.open(@db_path)

    try do
      fun.(conn)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Key-Value store (replaces JSON files for Store module)
  # ---------------------------------------------------------------------------

  @doc "Upserts a key-value pair (value is JSON-encoded)."
  def kv_put(conn, key, value) do
    {:ok, json} = Jason.encode(value)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?1, ?2)")
    :ok = Exqlite.Sqlite3.bind(stmt, [key, json])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  @doc "Gets a value by key. Returns {:ok, decoded} or {:error, :not_found}."
  def kv_get(conn, key) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT value FROM kv_store WHERE key = ?1")
    :ok = Exqlite.Sqlite3.bind(stmt, [key])

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [json]} -> {:ok, Jason.decode!(json)}
        :done -> {:error, :not_found}
      end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  @doc "Lists all keys matching a prefix."
  def kv_list_keys(conn, prefix) do
    like = prefix <> "%"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT key FROM kv_store WHERE key LIKE ?1")
    :ok = Exqlite.Sqlite3.bind(stmt, [like])
    keys = collect_rows(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    keys
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [key]} -> collect_rows(conn, stmt, [key | acc])
      :done -> Enum.reverse(acc)
    end
  end

  @doc "Deletes a key from the kv store."
  def kv_delete(conn, key) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "DELETE FROM kv_store WHERE key = ?1")
    :ok = Exqlite.Sqlite3.bind(stmt, [key])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Agent Metrics
  # ---------------------------------------------------------------------------

  @doc """
  Records an execution metric for an agent.

  Expects a map with keys:
    :agent_name, :task_id, :success (bool), :duration_ms, :tokens_used
  """
  def record_metric(metric) do
    if Application.get_env(:shazam, :store_backend) != :sqlite do
      :ok
    else
      with_conn(fn conn ->
        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(conn, """
          INSERT INTO agent_metrics (agent_name, task_id, success, duration_ms, tokens_used, recorded_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          """)

        :ok =
          Exqlite.Sqlite3.bind(stmt, [
            to_string(metric[:agent_name]),
            to_string(metric[:task_id] || ""),
            if(metric[:success], do: 1, else: 0),
            metric[:duration_ms] || 0,
            metric[:tokens_used] || 0,
            DateTime.to_iso8601(DateTime.utc_now())
          ])

        :done = Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        :ok
      end)
    end
  end

  @doc """
  Returns aggregated metrics for an agent (or all agents when agent_name is nil).

  Returns a map:
    %{total: n, successes: n, failures: n, avg_duration_ms: f, total_tokens: n}
  """
  @empty_metrics %{total: 0, successes: 0, failures: 0, avg_duration_ms: 0.0, total_tokens: 0}

  def get_metrics(agent_name \\ nil) do
    if Application.get_env(:shazam, :store_backend) != :sqlite do
      @empty_metrics
    else
      with_conn(fn conn ->
        {sql, bindings} =
          if agent_name do
            {"""
             SELECT COUNT(*), SUM(success), AVG(duration_ms), SUM(tokens_used)
             FROM agent_metrics WHERE agent_name = ?1
             """, [to_string(agent_name)]}
          else
            {"""
             SELECT COUNT(*), SUM(success), AVG(duration_ms), SUM(tokens_used)
             FROM agent_metrics
             """, []}
          end

        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
        :ok = Exqlite.Sqlite3.bind(stmt, bindings)

        result =
          case Exqlite.Sqlite3.step(conn, stmt) do
            {:row, [total, successes, avg_dur, total_tokens]} ->
              total = total || 0
              successes = successes || 0

              %{
                total: total,
                successes: successes,
                failures: total - successes,
                avg_duration_ms: avg_dur || 0.0,
                total_tokens: total_tokens || 0
              }

            :done ->
              @empty_metrics
          end

        Exqlite.Sqlite3.release(conn, stmt)
        result
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Event Log
  # ---------------------------------------------------------------------------

  @doc "Appends an event to the event_log table."
  def log_event(event_type, payload \\ %{}) do
    if Application.get_env(:shazam, :store_backend) != :sqlite do
      :ok
    else
      with_conn(fn conn ->
        {:ok, json} = Jason.encode(payload)

        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(conn, """
          INSERT INTO event_log (event_type, payload, recorded_at)
          VALUES (?1, ?2, ?3)
          """)

        :ok = Exqlite.Sqlite3.bind(stmt, [event_type, json, DateTime.to_iso8601(DateTime.utc_now())])
        :done = Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        :ok
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Migrations
  # ---------------------------------------------------------------------------

  defp run_migrations(conn) do
    # Ensure the version tracking table exists first
    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER NOT NULL
      )
      """)

    current = current_version(conn)

    if current < @schema_version do
      Logger.info("[Repo] Migrating from v#{current} to v#{@schema_version}")
      migrate(conn, current)
      set_version(conn, @schema_version)
    end
  end

  defp current_version(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT version FROM schema_version LIMIT 1")

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [v]} -> v
        :done -> 0
      end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp set_version(conn, version) do
    :ok = exec(conn, "DELETE FROM schema_version")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO schema_version (version) VALUES (?1)")
    :ok = Exqlite.Sqlite3.bind(stmt, [version])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end

  # --- v0 → v1 ---------------------------------------------------------------

  defp migrate(conn, v) when v < 1 do
    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS kv_store (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """)

    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS tasks (
        id            TEXT PRIMARY KEY,
        title         TEXT NOT NULL,
        description   TEXT,
        status        TEXT NOT NULL DEFAULT 'pending',
        assigned_to   TEXT,
        created_by    TEXT,
        parent_task_id TEXT,
        depends_on    TEXT,
        company       TEXT,
        result        TEXT,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
      )
      """)

    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS companies (
        name    TEXT PRIMARY KEY,
        config  TEXT NOT NULL
      )
      """)

    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS agent_metrics (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_name   TEXT NOT NULL,
        task_id      TEXT,
        success      INTEGER NOT NULL DEFAULT 0,
        duration_ms  INTEGER NOT NULL DEFAULT 0,
        tokens_used  INTEGER NOT NULL DEFAULT 0,
        recorded_at  TEXT NOT NULL
      )
      """)

    :ok =
      exec(conn, """
      CREATE INDEX IF NOT EXISTS idx_agent_metrics_agent ON agent_metrics(agent_name)
      """)

    :ok =
      exec(conn, """
      CREATE TABLE IF NOT EXISTS event_log (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        event_type   TEXT NOT NULL,
        payload      TEXT,
        recorded_at  TEXT NOT NULL
      )
      """)

    :ok =
      exec(conn, """
      CREATE INDEX IF NOT EXISTS idx_event_log_type ON event_log(event_type)
      """)

    # If there are existing JSON files, migrate them into the kv_store
    migrate_json_files(conn)

    migrate(conn, 1)
  end

  # Terminal — already at target version
  defp migrate(_conn, _v), do: :ok

  # ---------------------------------------------------------------------------
  # One-time JSON → SQLite data migration
  # ---------------------------------------------------------------------------

  defp migrate_json_files(conn) do
    json_dir = @data_dir

    ~w(tasks company workspace)
    |> Enum.each(fn key ->
      path = Path.join(json_dir, "#{key}.json")

      if File.exists?(path) do
        case File.read(path) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, data} ->
                {:ok, json} = Jason.encode(data)
                {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?1, ?2)")
                :ok = Exqlite.Sqlite3.bind(stmt, [key, json])
                :done = Exqlite.Sqlite3.step(conn, stmt)
                Exqlite.Sqlite3.release(conn, stmt)

                # Rename the old file so it is not imported again
                File.rename(path, path <> ".bak")
                Logger.info("[Repo] Migrated #{key}.json → SQLite kv_store")

              _ ->
                Logger.warning("[Repo] Could not decode #{path}, skipping")
            end

          _ ->
            :ok
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp exec(conn, sql) do
    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> raise "SQL exec failed: #{inspect(reason)}\n#{sql}"
    end
  end
end

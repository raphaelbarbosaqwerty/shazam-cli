defmodule Shazam.FileLoggerTest do
  use ExUnit.Case, async: false

  alias Shazam.FileLogger

  setup do
    FileLogger.init()

    on_exit(fn ->
      # Clean up today's test log
      path = FileLogger.log_file_path()
      if File.exists?(path), do: File.rm(path)
    end)

    :ok
  end

  # ── init/0 ───────────────────────────────────────────────

  describe "init/0" do
    test "creates the log directory" do
      FileLogger.init()
      assert File.dir?(FileLogger.log_dir())
    end
  end

  # ── log/2 ────────────────────────────────────────────────

  describe "log/2" do
    test "writes a log line to the file" do
      FileLogger.log(:info, "Test log message")
      content = File.read!(FileLogger.log_file_path())

      assert content =~ "[info]"
      assert content =~ "Test log message"
    end

    test "includes timestamp in log line" do
      FileLogger.log(:info, "Timestamped")
      content = File.read!(FileLogger.log_file_path())

      # Should match YYYY-MM-DD HH:MM:SS format
      assert content =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/
    end

    test "appends multiple log lines" do
      FileLogger.log(:info, "Line one")
      FileLogger.log(:warn, "Line two")
      FileLogger.log(:error, "Line three")

      content = File.read!(FileLogger.log_file_path())
      lines = String.split(content, "\n", trim: true)

      assert length(lines) >= 3
    end

    test "supports different log levels" do
      FileLogger.log(:info, "info msg")
      FileLogger.log(:warn, "warn msg")
      FileLogger.log(:error, "error msg")
      FileLogger.log(:debug, "debug msg")

      content = File.read!(FileLogger.log_file_path())
      assert content =~ "[info]"
      assert content =~ "[warn]"
      assert content =~ "[error]"
      assert content =~ "[debug]"
    end
  end

  # ── Convenience functions ────────────────────────────────

  describe "convenience functions" do
    test "info/1 writes info level" do
      FileLogger.info("info shortcut")
      content = File.read!(FileLogger.log_file_path())
      assert content =~ "[info]"
      assert content =~ "info shortcut"
    end

    test "error/1 writes error level" do
      FileLogger.error("error shortcut")
      content = File.read!(FileLogger.log_file_path())
      assert content =~ "[error]"
    end

    test "warn/1 writes warn level" do
      FileLogger.warn("warn shortcut")
      content = File.read!(FileLogger.log_file_path())
      assert content =~ "[warn]"
    end

    test "debug/1 writes debug level" do
      FileLogger.debug("debug shortcut")
      content = File.read!(FileLogger.log_file_path())
      assert content =~ "[debug]"
    end
  end

  # ── log_file_path/0 ─────────────────────────────────────

  describe "log_file_path/0" do
    test "returns path with today's date" do
      path = FileLogger.log_file_path()
      today = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

      assert path =~ "shazam-#{today}.log"
    end

    test "path is inside log_dir" do
      path = FileLogger.log_file_path()
      assert String.starts_with?(path, FileLogger.log_dir())
    end
  end

  # ── list_logs/0 ──────────────────────────────────────────

  describe "list_logs/0" do
    test "returns a list of log file paths" do
      FileLogger.info("ensure file exists")
      logs = FileLogger.list_logs()

      assert is_list(logs)
      assert length(logs) >= 1
      assert Enum.all?(logs, &String.ends_with?(&1, ".log"))
    end

    test "only returns .log files" do
      # Create a non-log file in the log dir
      dummy = Path.join(FileLogger.log_dir(), "not_a_log.txt")
      File.write!(dummy, "noise")
      on_exit(fn -> File.rm(dummy) end)

      logs = FileLogger.list_logs()
      refute Enum.any?(logs, &String.ends_with?(&1, ".txt"))
    end
  end

  # ── cleanup/1 ────────────────────────────────────────────

  describe "cleanup/1" do
    test "does not remove recent log files" do
      FileLogger.info("fresh log")
      FileLogger.cleanup(7)

      # Today's log should still exist
      assert File.exists?(FileLogger.log_file_path())
    end

    test "removes old log files" do
      # Create a fake old log file
      old_date = "2020-01-01"
      old_path = Path.join(FileLogger.log_dir(), "shazam-#{old_date}.log")
      File.write!(old_path, "old data")

      # Set its mtime to the past
      past = {{2020, 1, 1}, {0, 0, 0}}
      File.touch!(old_path, past)

      FileLogger.cleanup(1)

      refute File.exists?(old_path)
    end

    test "cleanup with 0 days removes all but current" do
      # Create a file that will look old by mtime
      old_path = Path.join(FileLogger.log_dir(), "shazam-2019-06-15.log")
      File.write!(old_path, "ancient")
      File.touch!(old_path, {{2019, 6, 15}, {0, 0, 0}})

      FileLogger.cleanup(0)

      refute File.exists?(old_path)
    end
  end
end

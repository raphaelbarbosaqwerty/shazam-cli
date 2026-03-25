defmodule Shazam.CLI.Commands.Daemon do
  @moduledoc """
  CLI commands for managing the Shazam daemon (persistent backend).

  Usage:
    shazam daemon start   — Start the backend as a background daemon
    shazam daemon stop    — Stop the running daemon
    shazam daemon status  — Show daemon status
    shazam daemon restart — Restart the daemon
  """

  alias Shazam.CLI.Formatter

  @daemon_port 4040
  @pid_file "~/.shazam/daemon.pid"

  def run(["start" | _opts]) do
    if daemon_alive?() do
      Formatter.success("Daemon is already running on port #{@daemon_port}")
      show_status()
    else
      start_daemon()
    end
  end

  def run(["stop" | _]) do
    if daemon_alive?() do
      stop_daemon()
      Formatter.success("Daemon stopped")
    else
      IO.puts("  Daemon is not running")
    end
  end

  def run(["restart" | _]) do
    if daemon_alive?() do
      stop_daemon()
      Process.sleep(1000)
    end
    start_daemon()
  end

  def run(["status" | _]) do
    show_status()
  end

  def run(_) do
    IO.puts("")
    IO.puts("  \e[33mShazam Daemon\e[0m — persistent backend service")
    IO.puts("")
    IO.puts("  Commands:")
    IO.puts("    \e[36mshazam daemon start\e[0m    Start the backend daemon")
    IO.puts("    \e[36mshazam daemon stop\e[0m     Stop the running daemon")
    IO.puts("    \e[36mshazam daemon status\e[0m   Show daemon status")
    IO.puts("    \e[36mshazam daemon restart\e[0m  Restart the daemon")
    IO.puts("")
  end

  # ── Public API (used by Repl to detect daemon) ──────

  def daemon_alive? do
    port_open?(@daemon_port)
  end

  def daemon_port, do: @daemon_port

  # ── Private ────────────────────────────────────────

  defp start_daemon do
    core_dir = find_core_dir()
    unless core_dir do
      Formatter.error("shazam-core not found. Expected at ~/.shazam-install/shazam-core/")
      System.halt(1)
    end

    Formatter.info("Starting Shazam daemon...")

    # Start Elixir in background using nohup + shell
    # --erl "-detached" passes the detached flag to the Erlang VM
    cmd = """
    cd #{core_dir} && \
    SHAZAM_DAEMON=true \
    SHAZAM_PORT=#{@daemon_port} \
    nohup elixir --erl "-detached" -S mix run --no-halt \
    >> #{Path.expand("~/.shazam/logs/daemon.stdout.log")} 2>&1 &
    """

    # Ensure log dir exists
    File.mkdir_p!(Path.expand("~/.shazam/logs"))

    System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)

    # Wait for daemon to be ready
    IO.write("  Waiting for daemon")
    started = Enum.reduce_while(1..30, false, fn _, _acc ->
      Process.sleep(500)
      IO.write(".")
      if port_open?(@daemon_port) do
        {:halt, true}
      else
        {:cont, false}
      end
    end)

    IO.puts("")

    if started do
      Formatter.success("Daemon started on port #{@daemon_port}")
      show_status()
    else
      Formatter.error("Daemon failed to start within 15 seconds")
      IO.puts("  Check logs: ~/.shazam/logs/")
    end
  end

  defp stop_daemon do
    pid_file = Path.expand(@pid_file)
    case File.read(pid_file) do
      {:ok, pid_str} ->
        pid = String.trim(pid_str)
        System.cmd("kill", [pid], stderr_to_stdout: true)
        File.rm(pid_file)
        # Wait for port to close
        Enum.reduce_while(1..10, :ok, fn _, _ ->
          Process.sleep(500)
          if port_open?(@daemon_port), do: {:cont, :ok}, else: {:halt, :ok}
        end)

      {:error, _} ->
        # Try to find and kill by port
        case System.cmd("lsof", ["-ti", ":#{@daemon_port}"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.each(fn pid ->
              System.cmd("kill", [pid], stderr_to_stdout: true)
            end)
          _ -> :ok
        end
    end
  end

  defp show_status do
    if daemon_alive?() do
      # Try to get health info from the REST API
      case fetch_health() do
        {:ok, health} ->
          IO.puts("")
          IO.puts("  \e[32m● Daemon running\e[0m")
          IO.puts("    Port: #{health["port"] || @daemon_port}")
          IO.puts("    PID: #{health["pid"] || "?"}")
          uptime = health["uptime_seconds"] || 0
          IO.puts("    Uptime: #{format_uptime(uptime)}")
          IO.puts("    Memory: #{health["memory_mb"] || "?"}MB")
          companies = health["companies"] || []
          if companies != [] do
            IO.puts("    Projects: #{Enum.join(companies, ", ")}")
          end
          IO.puts("")

        {:error, _} ->
          IO.puts("")
          IO.puts("  \e[32m● Daemon running\e[0m on port #{@daemon_port}")
          IO.puts("    (health endpoint not available)")
          IO.puts("")
      end
    else
      IO.puts("")
      IO.puts("  \e[31m● Daemon offline\e[0m")
      IO.puts("    Start with: \e[36mshazam daemon start\e[0m")
      IO.puts("")
    end
  end

  defp fetch_health do
    # Ensure inets/ssl are started for httpc
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    url = ~c"http://127.0.0.1:#{@daemon_port}/api/health"
    case :httpc.request(:get, {url, []}, [timeout: 2000], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(to_string(body))
      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp port_open?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end

  defp find_core_dir do
    home = System.get_env("HOME") || "."
    path = Path.join([home, ".shazam-install", "shazam-core"])
    if File.dir?(path), do: path, else: nil
  end

  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end
end

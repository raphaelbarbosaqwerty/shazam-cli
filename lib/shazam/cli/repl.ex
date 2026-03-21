defmodule Shazam.CLI.Repl do
  @moduledoc """
  Entry point for the interactive Shazam shell.
  Boots OTP, parses config, and hands off to the Rust TUI.
  """

  alias Shazam.CLI.Formatter

  # ── Public API ───────────────────────────────────────────

  def start(opts \\ []) do
    yaml_file = opts[:file] || default_yaml()
    port = opts[:port] || 4040

    config = case Shazam.CLI.YamlParser.parse(yaml_file) do
      {:ok, config} -> config
      {:error, reason} ->
        Formatter.error(reason)
        Formatter.dim("Run 'shazam init' to create a config")
        System.halt(1)
    end

    company_name = config.name

    # Boot OTP (lightweight — no company started yet)
    Application.put_env(:shazam, :port, port)

    # Suppress ALL logs — prevents [TaskBoard], [RalphLoop] etc.
    # from leaking into the TUI terminal.
    Application.ensure_all_started(:logger)
    Logger.configure(level: :none)
    :logger.set_primary_config(:level, :none)

    Application.ensure_all_started(:shazam)

    # Set workspace FIRST (before sync, so task files are found)
    workspace = config[:workspace] || File.cwd!()
    Application.put_env(:shazam, :workspace, workspace)
    Shazam.Store.save("workspace", %{"path" => workspace})

    # Set workspaces for multi-repo support
    if config[:workspaces] do
      Application.put_env(:shazam, :workspaces, config.workspaces)
    end

    # Fresh start: reset metrics and sync task files (AFTER workspace is set)
    clear_previous_session(company_name)

    # Set tech_stack if present in config
    if config[:tech_stack], do: Application.put_env(:shazam, :tech_stack, config.tech_stack)

    # Initialize file logger
    Shazam.FileLogger.init()
    Shazam.FileLogger.info("REPL started | company=#{company_name} workspace=#{workspace}")

    # Require Rust TUI — no fallback
    if Shazam.CLI.TuiPort.available?() do
      Shazam.FileLogger.info("Using Rust TUI")
      Shazam.CLI.TuiPort.start(%{
        name: company_name,
        config: config,
        agents: config.agents,
        workspace: workspace
      })
    else
      IO.puts("")
      IO.puts("  \e[31mError:\e[0m shazam-tui binary not found.")
      IO.puts("")
      IO.puts("  The interactive shell requires the Rust TUI binary.")
      IO.puts("  To fix this, install Rust and rebuild:")
      IO.puts("")
      IO.puts("  \e[33m1.\e[0m Install Rust:  \e[36mcurl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh\e[0m")
      IO.puts("  \e[33m2.\e[0m Rebuild:       \e[36mcd ~/.shazam-cli && ./build.sh\e[0m")
      IO.puts("")
      System.halt(1)
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp clear_previous_session(_company_name) do
    # Reset metrics for a fresh session view
    if Code.ensure_loaded?(Shazam.Metrics) do
      try do
        Shazam.Metrics.reset()
      catch
        _, _ -> :ok
      end
    end

    # Import tasks from .shazam/tasks/ markdown files
    # The sync handles deduplication — only imports tasks not already in ETS
    try do
      Shazam.TaskFiles.sync_from_files()
    catch
      _, _ -> :ok
    end
  end

  defp default_yaml do
    if File.exists?(".shazam/shazam.yaml"), do: ".shazam/shazam.yaml", else: "shazam.yaml"
  end
end

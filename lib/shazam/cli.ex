defmodule Shazam.CLI do
  @moduledoc """
  Main entry point for the `shazam` escript binary.

  All heavy command implementations live in dedicated sub-modules under
  `Shazam.CLI.Commands.*`.  This module is responsible only for arg
  parsing / dispatch and the lightweight commands (help, version, update,
  default).

  Usage:
    shazam                   Interactive REPL (if shazam.yaml exists)
    shazam shell             Interactive REPL terminal
    shazam init              Create shazam.yaml in current directory
    shazam start             Boot server from shazam.yaml
    shazam status            Show running companies & agents
    shazam stop              Stop a company
    shazam logs [agent]      Stream live events
    shazam task "title"      Create a task
    shazam org               Show org chart
    shazam agent add <name>  Add agent to running company
    shazam apply             Apply shazam.yaml changes
    shazam dashboard         Interactive TUI dashboard
    shazam help              Show this help
  """

  alias Shazam.CLI.Formatter
  alias Shazam.CLI.Shared

  def main(args) do
    case args do
      ["init" | rest]        -> Shazam.CLI.Commands.Init.run(rest)
      ["shell" | rest]       -> cmd_shell(rest)
      ["start" | rest]       -> Shazam.CLI.Commands.Start.run(rest)
      ["status" | rest]      -> Shazam.CLI.Commands.Status.run(rest)
      ["stop" | rest]        -> Shazam.CLI.Commands.Stop.run(rest)
      ["logs" | rest]        -> Shazam.CLI.Commands.Logs.run(rest)
      ["task" | rest]        -> Shazam.CLI.Commands.Task.run(rest)
      ["org" | rest]         -> Shazam.CLI.Commands.Org.run(rest)
      ["agent", "add" | rest] -> Shazam.CLI.Commands.AgentAdd.run(rest)
      ["apply" | rest]       -> Shazam.CLI.Commands.Apply.run(rest)
      ["dashboard" | rest]   -> Shazam.CLI.Commands.Dashboard.run(rest)
      ["help" | _]           -> cmd_help()
      ["--help" | _]         -> cmd_help()
      ["-h" | _]             -> cmd_help()
      ["version" | _]        -> cmd_version()
      ["-v" | _]             -> cmd_version()
      ["--version" | _]      -> cmd_version()
      ["update" | _]         -> cmd_update()
      []                     -> cmd_default()
      [unknown | _] ->
        Formatter.error("Unknown command: #{unknown}")
        IO.puts("")
        cmd_help()
    end
  end

  # ── default (no args) ──────────────────────────────────────

  defp cmd_default do
    yaml = Shared.default_yaml()

    if File.exists?(yaml) do
      cmd_shell([])
    else
      IO.puts("")
      Formatter.header("Welcome to Shazam")
      IO.puts("")
      IO.puts(["  ", IO.ANSI.faint(), "No shazam.yaml found in this directory.", IO.ANSI.reset()])
      IO.puts("")
      IO.puts(["  Get started:"])
      IO.puts(["    1. ", IO.ANSI.cyan(), "shazam init", IO.ANSI.reset(), "   — Create a new project config"])
      IO.puts(["    2. ", IO.ANSI.cyan(), "shazam start", IO.ANSI.reset(), "  — Boot agents and start working"])
      IO.puts(["    3. ", IO.ANSI.cyan(), "shazam help", IO.ANSI.reset(), "   — See all commands"])
      IO.puts("")

      # Check if Claude CLI is available
      case System.cmd("sh", ["-c", "which claude 2>/dev/null"], stderr_to_stdout: true) do
        {_, 0} ->
          Formatter.success("Claude CLI detected")

        _ ->
          Formatter.warning("Claude CLI not found")
          IO.puts(["    Install: ", IO.ANSI.cyan(), "npm install -g @anthropic-ai/claude-code", IO.ANSI.reset()])
      end

      IO.puts("")
    end
  end

  # ── shell (REPL) ───────────────────────────────────────────

  defp cmd_shell(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer, file: :string],
        aliases: [p: :port, f: :file]
      )

    Shazam.CLI.Repl.start(opts)
  end

  # ── version ────────────────────────────────────────────────

  defp cmd_version do
    IO.puts([IO.ANSI.bright(), "shazam", IO.ANSI.reset(), " v0.1.0"])
    IO.puts([IO.ANSI.faint(), "  Elixir #{System.version()} • OTP #{System.otp_release()}", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Data: ~/.shazam/", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Logs: ~/.shazam/logs/", IO.ANSI.reset()])
  end

  # ── update ─────────────────────────────────────────────────

  defp cmd_update do
    Formatter.info("Checking for updates...")

    current = "0.1.0"

    if Code.ensure_loaded?(Mix) do
      Formatter.info("Running in development mode. Use 'mix escript.build && mix escript.install' to update.")
    else
      escript_path = System.find_executable("shazam") || Path.expand("~/bin/shazam")

      IO.puts([
        "  ",
        IO.ANSI.faint(),
        "Current version: v#{current}",
        IO.ANSI.reset()
      ])

      IO.puts([
        "  ",
        IO.ANSI.faint(),
        "Binary: #{escript_path}",
        IO.ANSI.reset()
      ])

      IO.puts("")
      Formatter.info("To update manually:")
      IO.puts("    cd #{source_dir()} && ./build.sh")
      IO.puts("")
      Formatter.dim("This builds both the Elixir escript and Rust TUI binary.")
    end
  end

  defp source_dir do
    home_bin = Path.expand("~/bin/shazam")

    cond do
      File.exists?(home_bin) -> Path.expand("~/Projects/LiberdadeFinanceira/Clawster")
      true -> Path.expand("~/Projects/LiberdadeFinanceira/Clawster")
    end
  end

  # ── help ───────────────────────────────────────────────────

  defp cmd_help do
    Formatter.banner_static()

    IO.puts("""
      #{IO.ANSI.bright()}USAGE#{IO.ANSI.reset()}
        shazam <command> [options]

      #{IO.ANSI.bright()}COMMANDS#{IO.ANSI.reset()}
        shell                   Interactive REPL terminal (default if config exists)
        init                    Create shazam.yaml in current directory
        start                   Boot server and company from shazam.yaml
        status                  Show running companies and agents
        stop                    Stop a company
        logs [agent]            Stream live agent events
        task "title" [--to ag]  Create a new task
        org                     Display org chart tree
        agent add <name>        Add agent to running company
        apply                   Apply shazam.yaml to running system
        dashboard               Interactive TUI dashboard
        version                 Show version info
        update                  Check for updates

      #{IO.ANSI.bright()}OPTIONS#{IO.ANSI.reset()}
        --company, -c NAME      Target company (default: from shazam.yaml)
        --port, -p PORT         Server port (default: 4040)
        --file, -f FILE         Config file (default: shazam.yaml)

      #{IO.ANSI.bright()}EXAMPLES#{IO.ANSI.reset()}
        shazam                 Enter interactive REPL (if config exists)
        shazam shell           Enter interactive REPL
        shazam init
        shazam start
        shazam task "Implement login page" --to dev_senior
        shazam agent add designer --role "UX Designer" --supervisor pm
        shazam logs dev_senior
        shazam org

      #{IO.ANSI.faint()}https://github.com/your-org/shazam#{IO.ANSI.reset()}
    """)
  end
end

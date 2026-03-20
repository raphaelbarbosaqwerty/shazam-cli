defmodule Shazam.CLI do
  @version "0.4.0"
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
      IO.puts(["    2. ", IO.ANSI.cyan(), "shazam", IO.ANSI.reset(), "        — Open the interactive shell"])
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
    IO.puts([IO.ANSI.bright(), "shazam", IO.ANSI.reset(), " v0.4.0"])
    IO.puts([IO.ANSI.faint(), "  Elixir #{System.version()} • OTP #{System.otp_release()}", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Data: ~/.shazam/", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Logs: ~/.shazam/logs/", IO.ANSI.reset()])
  end

  # ── update ─────────────────────────────────────────────────

  defp cmd_update do
    shazam_dir = Path.expand("~/.shazam-cli")

    Formatter.info("Updating Shazam...")
    IO.puts("")

    if File.dir?(shazam_dir) do
      IO.puts("  Fetching latest version...")

      {_, 0} = System.cmd("git", ["fetch", "origin"], cd: shazam_dir, stderr_to_stdout: true)

      # Check if there are updates
      {local, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: shazam_dir)
      {remote, 0} = System.cmd("git", ["rev-parse", "origin/main"], cd: shazam_dir)

      if String.trim(local) == String.trim(remote) do
        Formatter.success("Already up to date! (v#{@version})")
      else
        IO.puts("  New version available. Updating...")
        System.cmd("git", ["reset", "--hard", "origin/main"], cd: shazam_dir, stderr_to_stdout: true)

        IO.puts("  Rebuilding...")
        build_script = Path.join(shazam_dir, "build.sh")

        if File.exists?(build_script) do
          case System.cmd("bash", [build_script], cd: shazam_dir, stderr_to_stdout: true, env: [{"PATH", "#{System.get_env("HOME")}/.cargo/bin:#{System.get_env("HOME")}/bin:#{System.get_env("PATH")}"}]) do
            {_output, 0} ->
              IO.puts("")
              Formatter.success("Shazam updated successfully!")
              Formatter.dim("Restart your shell session to use the new version.")

            {output, _code} ->
              IO.puts("")
              Formatter.error("Build failed:")
              IO.puts(output)
          end
        else
          Formatter.error("build.sh not found at #{build_script}")
        end
      end
    else
      IO.puts("  Shazam was not installed via setup.sh.")
      IO.puts("  Run the installer to set up auto-update:")
      IO.puts("")
      IO.puts("  \e[36mcurl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash\e[0m")
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

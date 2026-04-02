defmodule Shazam.CLI do
  @version Mix.Project.config()[:version]
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
    shazam dashboard         Open desktop dashboard (installs if needed)
    shazam dashboard --tui   Interactive TUI dashboard
    shazam doctor            System health diagnostics
    shazam sync              Sync IDE configs (Claude/Gemini/Cursor/Codex)
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
      ["doctor" | _]         -> Shazam.CLI.Commands.Doctor.run()
      ["sync" | rest]        -> Shazam.CLI.Commands.Sync.run(rest)
      ["help" | _]           -> cmd_help()
      ["--help" | _]         -> cmd_help()
      ["-h" | _]             -> cmd_help()
      ["version" | _]        -> cmd_version()
      ["-v" | _]             -> cmd_version()
      ["--version" | _]      -> cmd_version()
      ["update" | _]         -> cmd_update()
      ["daemon" | rest]      -> Shazam.CLI.Commands.Daemon.run(rest)
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
    IO.puts([IO.ANSI.bright(), "shazam", IO.ANSI.reset(), " v#{@version}"])
    IO.puts([IO.ANSI.faint(), "  Elixir #{System.version()} • OTP #{System.otp_release()}", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Data: ~/.shazam/", IO.ANSI.reset()])
    IO.puts([IO.ANSI.faint(), "  Logs: ~/.shazam/logs/", IO.ANSI.reset()])
  end

  # ── update ─────────────────────────────────────────────────

  defp cmd_update do
    # Support both old (~/.shazam-cli) and new (~/.shazam-install/) layout
    install_dir = Path.expand("~/.shazam-install")
    cli_dir = Path.join(install_dir, "shazam-cli")
    core_dir = Path.join(install_dir, "shazam-core")
    legacy_dir = Path.expand("~/.shazam-cli")

    shazam_dir = cond do
      File.dir?(cli_dir) -> cli_dir
      File.dir?(legacy_dir) -> legacy_dir
      true -> nil
    end

    Formatter.info("Updating Shazam...")
    IO.puts("")

    if shazam_dir do
      # Update core first if it exists
      if File.dir?(core_dir) do
        IO.puts("  Updating shazam-core...")
        System.cmd("git", ["fetch", "origin", "--tags", "--force"], cd: core_dir, stderr_to_stdout: true)
        case System.cmd("git", ["describe", "--tags", "--abbrev=0", "origin/main"], cd: core_dir, stderr_to_stdout: true) do
          {tag, 0} ->
            tag = String.trim(tag)
            if tag != "" do
              System.cmd("git", ["checkout", tag, "--quiet"], cd: core_dir, stderr_to_stdout: true)
              IO.puts("  shazam-core: #{tag}")
            end
          _ -> :ok
        end
      end

      # Update CLI
      IO.puts("  Updating shazam-cli...")
      {_, _} = System.cmd("git", ["fetch", "origin", "--tags", "--force"], cd: shazam_dir, stderr_to_stdout: true)

      {latest_tag, exit_code} = System.cmd("git", ["describe", "--tags", "--abbrev=0", "origin/main"], cd: shazam_dir, stderr_to_stdout: true)
      latest_tag = String.trim(latest_tag)

      if exit_code != 0 or latest_tag == "" do
        IO.puts("  No tags found. Updating to latest main...")
        System.cmd("git", ["reset", "--hard", "origin/main"], cd: shazam_dir, stderr_to_stdout: true)
      else
        {current_tag, _} = System.cmd("git", ["describe", "--tags", "--exact-match", "HEAD"], cd: shazam_dir, stderr_to_stdout: true)
        current_tag = String.trim(current_tag)

        if current_tag == latest_tag do
          Formatter.success("Already up to date! #{latest_tag} (v#{@version})")
        else
          IO.puts("  New version available: #{latest_tag} (current: v#{@version}). Updating...")
          System.cmd("git", ["checkout", latest_tag], cd: shazam_dir, stderr_to_stdout: true)
          IO.puts("  shazam-cli: #{latest_tag}")

          IO.puts("  Rebuilding...")

          # Use setup.sh-style build: deps.get, cargo build, escript.build, install
          env = [{"PATH", "#{System.get_env("HOME")}/.cargo/bin:#{System.get_env("HOME")}/bin:#{System.get_env("PATH")}"}]

          IO.puts("    [1/3] Dependencies...")
          System.cmd("mix", ["deps.get", "--quiet"], cd: shazam_dir, stderr_to_stdout: true, env: env)

          IO.puts("    [2/3] Building TUI...")
          tui_dir = Path.join(shazam_dir, "shazam-tui")
          case System.cmd("cargo", ["build", "--release"], cd: tui_dir, stderr_to_stdout: true, env: env) do
            {_, 0} -> :ok
            {output, _} ->
              Formatter.error("TUI build failed:")
              IO.puts(output)
          end

          IO.puts("    [3/3] Building escript...")
          case System.cmd("mix", ["escript.build"], cd: shazam_dir, stderr_to_stdout: true, env: env) do
            {_, 0} ->
              # Install binaries
              bin_dir = Path.expand("~/bin")
              File.mkdir_p!(bin_dir)
              File.cp(Path.join(shazam_dir, "shazam-cli"), Path.join(bin_dir, "shazam-cli"))
              File.chmod(Path.join(bin_dir, "shazam-cli"), 0o755)
              File.cp(Path.join(tui_dir, "target/release/shazam-tui"), Path.join(bin_dir, "shazam-tui"))
              File.chmod(Path.join(bin_dir, "shazam-tui"), 0o755)
              # Symlinks
              File.rm(Path.join(bin_dir, "shazam"))
              File.ln_s(Path.join(bin_dir, "shazam-cli"), Path.join(bin_dir, "shazam"))
              File.rm(Path.join(bin_dir, "shz"))
              File.ln_s(Path.join(bin_dir, "shazam-cli"), Path.join(bin_dir, "shz"))

              IO.puts("")
              Formatter.success("Shazam updated to #{latest_tag}!")
              Formatter.dim("Restart your shell session to use the new version.")

            {output, _code} ->
              IO.puts("")
              Formatter.error("Build failed:")
              IO.puts(output)
          end
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
        daemon start|stop|status Manage the background daemon

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

      #{IO.ANSI.faint()}https://github.com/ShazamAI/shazam-cli#{IO.ANSI.reset()}
    """)
  end
end

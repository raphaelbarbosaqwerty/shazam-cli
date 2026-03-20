defmodule Shazam.CLI.Repl do
  @moduledoc """
  Interactive REPL terminal for Shazam with fixed-bottom prompt.

  Layout:
    Row 1..(H-3)  — Scroll region (events, command output)
    Row H-2       — Separator
    Row H-1       — Agent status bar (always visible)
    Row H         — Input prompt (fixed)
  """

  alias Shazam.CLI.Formatter
  alias Shazam.API.EventBus
  alias Shazam.TaskBoard
  alias Shazam.AgentInbox

  @prompt_prefix "shazam"

  @commands %{
    "/start" => "Start agents",
    "/stop" => "Stop agents (keep REPL open)",
    "/dashboard" => "Agent progress dashboard",
    "/status" => "Company and agent overview",
    "/agents" => "List all agents with status",
    "/org" => "Show org chart",
    "/tasks" => "List tasks (active/pending/running/completed/all) [--clear]",
    "/task" => "Create a new task: /task \"title\" [--to agent]",
    "/approve" => "Approve a pending task: /approve <id>",
    "/approve-all" => "Approve all pending tasks",
    "/reject" => "Reject a pending task: /reject <id> [reason]",
    "/msg" => "Send message to agent: /msg <agent> <message>",
    "/pause" => "Pause RalphLoop",
    "/resume" => "Resume RalphLoop",
    "/auto-approve" => "Toggle auto-approve: /auto-approve [on|off]",
    "/config" => "Show current configuration",
    "/clear" => "Clear scroll region",
    "/help" => "Show available commands",
    "/exit" => "Exit REPL (stops agents if running)"
  }

  # ── Boot ───────────────────────────────────────────────────

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

    # Suppress ALL logs before starting OTP apps — prevents [TaskBoard],
    # [RalphLoop], [SessionPool] etc. from leaking into the TUI terminal.
    Application.ensure_all_started(:logger)
    Logger.configure(level: :none)
    :logger.set_primary_config(:level, :none)

    Application.ensure_all_started(:shazam)

    # Fresh start: clear old tasks and companies from previous projects
    clear_previous_session(company_name)

    # Set workspace
    workspace = config[:workspace] || File.cwd!()
    Application.put_env(:shazam, :workspace, workspace)
    Shazam.Store.save("workspace", %{"path" => workspace})

    # Set workspaces for multi-repo support
    if config[:workspaces] do
      Application.put_env(:shazam, :workspaces, config.workspaces)
    end

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

  defp start_ansi_repl(config, company_name, workspace, port) do
    # Print banner BEFORE setting up scroll region
    Formatter.banner()
    IO.puts([
      "  ", IO.ANSI.faint(), config.name, IO.ANSI.reset(),
      "  •  ", IO.ANSI.faint(), "workspace: ", workspace, IO.ANSI.reset()
    ])
    IO.puts([
      "  Type ", IO.ANSI.cyan(), "/start", IO.ANSI.reset(),
      " to boot agents, or ", IO.ANSI.cyan(), "/help", IO.ANSI.reset(),
      " for commands\n"
    ])

    # Check if Claude CLI is available
    unless claude_cli_available?() do
      IO.puts([IO.ANSI.yellow(), "  \u26a0 ", IO.ANSI.reset(),
        "Claude CLI not found. Install it: ", IO.ANSI.cyan(), "npm install -g @anthropic-ai/claude-code", IO.ANSI.reset()])
      IO.puts([IO.ANSI.faint(), "  Agents won't be able to execute tasks without it.\n", IO.ANSI.reset()])
    end

    # Setup TUI (scroll region + chrome)
    tui = setup_tui(company_name)

    # Initialize shared input buffer
    :persistent_term.put(:shazam_input_buf, "")

    # Start the input reader in a separate process
    repl_pid = self()
    input_pid = spawn_link(fn -> input_loop(repl_pid, tui.height) end)

    # Trap exits so we can clean up on terminal kill / Ctrl+C from outside
    Process.flag(:trap_exit, true)

    # Main event loop — starts with running: false
    event_loop(%{
      company: company_name,
      config: config,
      input_pid: input_pid,
      port: port,
      tui: tui,
      running: false,
      pending_approval: []
    })
  end

  defp boot_agents(state) do
    config = state.config
    company_name = state.company
    tui = state.tui

    # Suppress ALL logs — Erlang and Elixir
    :logger.set_primary_config(:level, :none)
    Logger.configure(level: :none)

    # Subscribe to EventBus
    EventBus.subscribe()

    result = unless Shazam.RalphLoop.exists?(company_name) do
      company_config = %{
        name: company_name,
        mission: config.mission,
        agents: config.agents,
        domain_config: config[:domain_config] || %{}
      }

      case Shazam.start_company(company_config) do
        {:ok, _} ->
          tui_print(tui, [IO.ANSI.green(), "  ✓ ", IO.ANSI.reset(),
            "Agents started — #{length(config.agents)} agent(s)"])
          :ok
        {:error, {:already_started, _}} ->
          tui_print(tui, [IO.ANSI.yellow(), "  ⚡ ", IO.ANSI.reset(), "Already running"])
          :ok
        {:error, reason} ->
          tui_print(tui, [IO.ANSI.red(), "  ✗ ", IO.ANSI.reset(), "Failed: #{inspect(reason)}"])
          :error
      end
    else
      tui_print(tui, [IO.ANSI.yellow(), "  ⚡ ", IO.ANSI.reset(), "Already running"])
      :ok
    end

    if result == :ok do
      # Apply ralph_config from YAML
      if config[:ralph_config] do
        rc = config.ralph_config
        try do
          if rc[:qa_auto] do
            Application.put_env(:shazam, :qa_auto, true)
          end
          if rc[:auto_approve], do: Shazam.RalphLoop.set_auto_approve(company_name, true)
          Shazam.RalphLoop.set_config(company_name, "max_concurrent", rc[:max_concurrent] || 4)
          Shazam.RalphLoop.set_config(company_name, "poll_interval", rc[:poll_interval] || 5000)
          Shazam.RalphLoop.set_config(company_name, "module_lock", Map.get(rc, :module_lock, true))
          Shazam.RalphLoop.set_config(company_name, "peer_reassign", Map.get(rc, :peer_reassign, true))
          Shazam.RalphLoop.set_config(company_name, "auto_retry", rc[:auto_retry] || false)
          Shazam.RalphLoop.set_config(company_name, "max_retries", rc[:max_retries] || 2)
        catch
          _, _ -> :ok
        end
      end

      # Resume RalphLoop
      case Shazam.RalphLoop.resume(company_name) do
        {:ok, _} -> tui_print(tui, [IO.ANSI.green(), "  ✓ ", IO.ANSI.reset(), "RalphLoop active"])
        _ -> :ok
      end
    end

    result
  end

  # ── TUI Setup ──────────────────────────────────────────────

  defp terminal_size do
    rows = case :io.rows() do
      {:ok, r} -> r
      _ -> 24
    end
    cols = case :io.columns() do
      {:ok, c} -> c
      _ -> 80
    end
    {rows, cols}
  end

  defp setup_tui(company_name) do
    {height, width} = terminal_size()
    scroll_bottom = max(height - 3, 5)

    # Set scroll region (don't clear — banner is already printed above)
    IO.write("\e[1;#{scroll_bottom}r")

    tui = %{
      height: height,
      width: width,
      scroll_bottom: scroll_bottom,
      company: company_name
    }

    # Draw the chrome (separator, status bar, prompt)
    draw_chrome(tui)

    # Position cursor at bottom of scroll region
    IO.write("\e[#{scroll_bottom};1H")

    tui
  end

  defp draw_chrome(tui) do
    draw_separator(tui)
    draw_status_bar(tui)
    draw_prompt_line(tui)
  end

  defp draw_separator(tui) do
    row = tui.height - 2
    IO.write("\e[#{row};1H\e[2K")
    IO.write([IO.ANSI.faint(), IO.ANSI.cyan(), String.duplicate("─", tui.width), IO.ANSI.reset()])
  end

  defp draw_status_bar(tui) do
    row = tui.height - 1
    IO.write("\e[#{row};1H\e[2K")

    agents = try do
      Shazam.Company.agent_statuses(tui.company)
    catch
      _, _ -> []
    end

    if agents == [] do
      # Not running — show idle status
      IO.write([" ", IO.ANSI.faint(), "idle — /start to boot agents", IO.ANSI.reset()])
    else
      running = try do
        case Shazam.RalphLoop.status(tui.company) do
          %{running_tasks: tasks} ->
            tasks |> Enum.map(fn {_id, info} -> info[:agent_name] || info["agent_name"] end) |> MapSet.new()
          _ -> MapSet.new()
        end
      catch
        _, _ -> MapSet.new()
      end

      agent_parts = Enum.map(agents, fn a ->
        {icon, color} = if MapSet.member?(running, a.name) do
          {"●", IO.ANSI.green()}
        else
          {"○", IO.ANSI.faint()}
        end

        [" ", color, icon, " ", IO.ANSI.reset(), a.name]
      end)

      # Task counts
      task_counts = try do
        tasks = TaskBoard.list(%{company: tui.company})
        pending = Enum.count(tasks, & &1.status in [:pending, :awaiting_approval])
        running_t = Enum.count(tasks, & &1.status in [:running, :in_progress])
        done = Enum.count(tasks, & &1.status == :completed)
        [IO.ANSI.faint(), "  │  ", IO.ANSI.reset(),
         IO.ANSI.yellow(), "⏳#{running_t}", IO.ANSI.reset(), " ",
         IO.ANSI.blue(), "📋#{pending}", IO.ANSI.reset(), " ",
         IO.ANSI.green(), "✓#{done}", IO.ANSI.reset()]
      catch
        _, _ -> []
      end

      IO.write([" " | agent_parts] ++ task_counts)
    end
  end

  defp draw_prompt_line(tui) do
    row = tui.height
    IO.write("\e[#{row};1H\e[2K")
    IO.write(prompt_string())
  end

  defp refresh_chrome(state) do
    draw_separator(state.tui)
    draw_status_bar(state.tui)
    draw_prompt_line(state.tui)
  end

  # ── Scroll region output ───────────────────────────────────

  # Write content in the scroll region, preserving the input line
  defp tui_print(tui, content) do
    IO.write("\e7")                                    # Save cursor
    IO.write("\e[?7l")                                 # Disable line wrap
    IO.write("\e[#{tui.scroll_bottom};1H")             # Move to bottom of scroll region
    IO.write(["\n", content])                          # Newline (scrolls up) + content
    IO.write("\e[?7h")                                 # Re-enable line wrap
    IO.write("\e8")                                    # Restore cursor
    redraw_current_input(tui)
  end

  # Execute a function, capture its IO, and print in scroll region
  defp tui_exec(state, fun) do
    output = capture_io(fun)

    lines = String.split(output, "\n")
    IO.write("\e[?7l")                                 # Disable line wrap for all lines
    Enum.each(lines, fn line ->
      unless line == "" do
        IO.write("\e7")
        IO.write("\e[#{state.tui.scroll_bottom};1H")
        IO.write(["\n", line])
        IO.write("\e8")
      end
    end)
    IO.write("\e[?7h")                                 # Re-enable line wrap

    refresh_chrome(state)
    redraw_current_input(state.tui)
  end

  # Redraw the input line with whatever the user has typed so far
  defp redraw_current_input(tui) do
    buf = try do
      :persistent_term.get(:shazam_input_buf)
    catch
      _, _ -> ""
    end
    redraw_input(tui.height, buf)
  end

  defp capture_io(fun) do
    {:ok, pid} = StringIO.open("")
    old_gl = Process.group_leader()
    Process.group_leader(self(), pid)
    try do
      fun.()
    after
      Process.group_leader(self(), old_gl)
    end
    {:ok, {_, output}} = StringIO.close(pid)
    output
  end

  # ── Input reader process (raw mode with ghost text) ───────

  @command_names Map.keys(@commands) |> Enum.sort()
  @shortcuts %{"/a" => "/approve", "/aa" => "/approve-all", "/r" => "/reject", "/q" => "/exit"}
  @all_completions @command_names ++ Map.keys(@shortcuts)

  defp input_loop(repl_pid, height) do
    case enable_raw_mode() do
      :ok -> raw_loop(repl_pid, height, "", [])
      :fallback -> line_mode_loop(repl_pid, height, [])
    end
  end

  defp enable_raw_mode do
    case System.cmd("sh", ["-c", "stty raw -echo < /dev/tty"], stderr_to_stdout: true) do
      {_, 0} ->
        # Enable bracketed paste mode — terminal wraps pastes in \e[200~ ... \e[201~
        IO.write("\e[?2004h")
        :ok
      _ -> :fallback
    end
  catch
    _, _ -> :fallback
  end

  defp line_mode_loop(repl_pid, height, history) do
    case IO.gets(prompt_string()) do
      :eof -> send(repl_pid, {:input, :eof})
      {:error, _} -> send(repl_pid, {:input, :eof})
      data ->
        line = data |> to_string() |> String.trim()
        new_history = if line != "", do: [line | history] |> Enum.take(50), else: history
        send(repl_pid, {:input, line})
        line_mode_loop(repl_pid, height, new_history)
    end
  end

  defp disable_raw_mode do
    # Disable bracketed paste mode
    IO.write("\e[?2004l")
    System.cmd("sh", ["-c", "stty sane < /dev/tty"], stderr_to_stdout: true)
    :ok
  catch
    _, _ -> :ok
  end

  defp raw_loop(repl_pid, height, buf, history) do
    # Share current buffer so event_loop can redraw input after printing events
    :persistent_term.put(:shazam_input_buf, buf)
    redraw_input(height, buf)

    case read_key() do
      :eof ->
        disable_raw_mode()
        send(repl_pid, {:input, :eof})

      :enter ->
        IO.write("\n")
        line = String.trim(buf)
        new_history = if line != "", do: [line | history] |> Enum.take(50), else: history
        send(repl_pid, {:input, line})
        raw_loop(repl_pid, height, "", new_history)

      :tab ->
        # Complete the ghost suggestion
        case best_completion(buf) do
          nil -> raw_loop(repl_pid, height, buf, history)
          completion -> raw_loop(repl_pid, height, completion, history)
        end

      :backspace ->
        new_buf = if byte_size(buf) > 0, do: String.slice(buf, 0..-2//1), else: ""
        raw_loop(repl_pid, height, new_buf, history)

      :up ->
        # Navigate history
        case history do
          [prev | _] -> raw_loop(repl_pid, height, prev, history)
          [] -> raw_loop(repl_pid, height, buf, history)
        end

      :ctrl_c ->
        if buf == "" do
          disable_raw_mode()
          send(repl_pid, {:input, "/exit"})
        else
          raw_loop(repl_pid, height, "", history)
        end

      :ctrl_u ->
        raw_loop(repl_pid, height, "", history)

      :escape ->
        # Ignore escape sequences we don't handle
        raw_loop(repl_pid, height, buf, history)

      :paste_start ->
        pasted = read_paste_content("")
        {new_buf, token} = handle_paste(buf, pasted)
        if token do
          # Show the token visually in the scroll region
          IO.write("\e7\e[#{height - 3};1H")
          IO.write(["\n", IO.ANSI.faint(), "  ", token, IO.ANSI.reset()])
          IO.write("\e8")
        end
        raw_loop(repl_pid, height, new_buf, history)

      {:char, ch} ->
        raw_loop(repl_pid, height, buf <> ch, history)

      _ ->
        raw_loop(repl_pid, height, buf, history)
    end
  end

  defp redraw_input(height, buf) do
    prompt = prompt_string()
    prompt_len = String.length(@prompt_prefix) + 2  # "shazam> "
    cols = case :io.columns() do {:ok, c} -> c; _ -> 80 end
    max_input = cols - prompt_len - 1

    # Truncate visible portion if input exceeds terminal width
    visible_buf = if String.length(buf) > max_input do
      String.slice(buf, (String.length(buf) - max_input)..-1//1)
    else
      buf
    end

    ghost = case best_completion(buf) do
      nil -> ""
      completion ->
        rest = String.slice(completion, String.length(buf)..-1//1)
        available = max_input - String.length(visible_buf)
        rest = if available > 0, do: String.slice(rest, 0, available), else: ""
        if rest != "" do
          IO.ANSI.format([IO.ANSI.faint(), rest, IO.ANSI.reset()]) |> IO.chardata_to_string()
        else
          ""
        end
    end

    cursor_col = prompt_len + 1 + String.length(visible_buf)
    IO.write("\e[#{height};1H\e[2K#{prompt}#{visible_buf}#{ghost}")
    IO.write("\e[#{height};#{cursor_col}H")
  end

  defp best_completion(""), do: nil
  defp best_completion(buf) do
    # Only complete commands starting with /
    if String.starts_with?(buf, "/") do
      @all_completions
      |> Enum.find(fn cmd -> cmd != buf and String.starts_with?(cmd, buf) end)
    else
      nil
    end
  end

  # ── Paste handling ──────────────────────────────────────────

  @image_extensions ~w(.png .jpg .jpeg .gif .svg .webp .bmp .tiff)

  # Process pasted content: detect multi-line text or image paths
  # Returns {new_buffer, display_token | nil}
  defp handle_paste(buf, pasted) do
    lines = String.split(pasted, ~r/\r?\n/)
    |> Enum.reject(& &1 == "")

    cond do
      # Single line — just append to buffer
      length(lines) <= 1 ->
        {buf <> String.trim(pasted), nil}

      # Check if pasted content contains image file paths
      has_image_paths?(lines) ->
        img_num = next_counter(:shazam_image_count)
        image_paths = lines |> Enum.filter(&image_path?/1) |> Enum.map(&String.trim/1)
        store_attachment(:shazam_images, img_num, image_paths)
        token = "[Image ##{img_num}]"
        {buf <> token, "📎 #{token} (#{length(image_paths)} file(s))"}

      # Multi-line text paste
      true ->
        paste_num = next_counter(:shazam_paste_count)
        store_attachment(:shazam_pastes, paste_num, pasted)
        line_count = length(lines) - 1
        token = "[Pasted text ##{paste_num} +#{line_count} lines]"
        {buf <> token, "📋 #{token}"}
    end
  end

  defp has_image_paths?(lines) do
    Enum.any?(lines, &image_path?/1)
  end

  defp image_path?(line) do
    trimmed = String.trim(line)
    ext = Path.extname(trimmed) |> String.downcase()
    ext in @image_extensions and (File.exists?(trimmed) or String.starts_with?(trimmed, "/") or String.starts_with?(trimmed, "~"))
  end

  defp next_counter(key) do
    n = try do :persistent_term.get(key) catch _, _ -> 0 end
    :persistent_term.put(key, n + 1)
    n + 1
  end

  defp store_attachment(key, num, content) do
    store = try do :persistent_term.get(key) catch _, _ -> %{} end
    :persistent_term.put(key, Map.put(store, num, content))
  end

  @doc false
  # Expand paste/image tokens in text before sending to task descriptions
  def expand_attachments(text) do
    pastes = try do :persistent_term.get(:shazam_pastes) catch _, _ -> %{} end
    images = try do :persistent_term.get(:shazam_images) catch _, _ -> %{} end

    text = Regex.replace(~r/\[Pasted text #(\d+) \+\d+ lines\]/, text, fn full, num_str ->
      num = String.to_integer(num_str)
      case Map.get(pastes, num) do
        nil -> full
        content -> content
      end
    end)

    text = Regex.replace(~r/\[Image #(\d+)\]/, text, fn full, num_str ->
      num = String.to_integer(num_str)
      case Map.get(images, num) do
        nil -> full
        paths when is_list(paths) ->
          paths_str = Enum.map_join(paths, "\n", &"  - #{&1}")
          "[Image references]\n#{paths_str}"
        path -> "[Image: #{path}]"
      end
    end)

    text
  end

  defp read_key do
    case IO.read(:stdio, 1) do
      :eof -> :eof
      {:error, _} -> :eof
      <<3>> -> :ctrl_c       # Ctrl+C
      <<4>> -> :eof           # Ctrl+D
      <<9>> -> :tab
      <<13>> -> :enter        # CR
      <<10>> -> :enter        # LF
      <<21>> -> :ctrl_u       # Ctrl+U
      <<127>> -> :backspace   # DEL
      <<8>> -> :backspace     # BS
      <<27>> ->               # Escape sequence
        case IO.read(:stdio, 1) do
          "[" -> read_csi_sequence("")
          _ -> :escape
        end
      ch when is_binary(ch) ->
        if ch >= " ", do: {:char, ch}, else: :escape
      _ -> :escape
    end
  end

  # Read a CSI sequence: ESC [ <params> <final_byte>
  # Handles arrows (A/B/C/D) and numbered sequences like \e[200~ (bracketed paste)
  defp read_csi_sequence(params) do
    case IO.read(:stdio, 1) do
      ch when ch in ~w(0 1 2 3 4 5 6 7 8 9 ;) ->
        read_csi_sequence(params <> ch)
      "A" -> :up
      "B" -> :down
      "C" -> :right
      "D" -> :left
      "~" ->
        case params do
          "200" -> :paste_start    # Bracketed paste start
          _ -> :escape
        end
      _ -> :escape
    end
  end

  # Read pasted content until the bracketed paste end marker \e[201~
  defp read_paste_content(acc) do
    case IO.read(:stdio, 1) do
      :eof -> acc
      {:error, _} -> acc
      <<27>> ->
        # Check for paste end: \e[201~
        case IO.read(:stdio, 1) do
          "[" ->
            end_params = read_paste_end_params("")
            case end_params do
              {:end_paste, _} -> acc
              {:not_end, extra} -> read_paste_content(acc <> "\e[" <> extra)
            end
          ch when is_binary(ch) -> read_paste_content(acc <> "\e" <> ch)
          _ -> acc
        end
      ch when is_binary(ch) -> read_paste_content(acc <> ch)
      _ -> acc
    end
  end

  defp read_paste_end_params(params) do
    case IO.read(:stdio, 1) do
      ch when ch in ~w(0 1 2 3 4 5 6 7 8 9 ;) ->
        read_paste_end_params(params <> ch)
      "~" ->
        if params == "201", do: {:end_paste, params}, else: {:not_end, params <> "~"}
      ch when is_binary(ch) ->
        {:not_end, params <> ch}
      _ ->
        {:not_end, params}
    end
  end

  defp prompt_string do
    IO.ANSI.format([IO.ANSI.cyan(), @prompt_prefix, IO.ANSI.reset(), "> "])
    |> IO.chardata_to_string()
  end

  # ── Main event loop ────────────────────────────────────────

  defp event_loop(state) do
    receive do
      {:input, :eof} ->
        shutdown(state)

      {:input, ""} ->
        refresh_chrome(state)
        event_loop(state)

      {:input, line} ->
        case handle_command(line, state) do
          :exit -> shutdown(state)
          {:ok, new_state} -> event_loop(new_state)
        end

      {:event, event} ->
        new_state = handle_event(event, state)
        event_loop(new_state)

      {:EXIT, _pid, _reason} ->
        shutdown(state)
    end
  end

  defp shutdown(state) do
    # Restore terminal from raw mode
    disable_raw_mode()
    # Reset scroll region and clear screen
    IO.write("\e[r")
    IO.write("\e[2J\e[1;1H")

    # Suppress error logs during shutdown
    :logger.set_primary_config(:level, :none)
    Logger.configure(level: :none)

    Formatter.info("Shutting down...")
    Shazam.FileLogger.info("REPL shutdown initiated")

    if state.running do
      try do
        Shazam.RalphLoop.pause(state.company)
        Formatter.dim("  RalphLoop paused")
      catch
        _, _ -> :ok
      end

      try do
        Shazam.SessionPool.kill_all()
        Formatter.dim("  All Claude sessions terminated")
      catch
        _, _ -> :ok
      end

      # Kill any orphaned claude processes spawned by this session
      try do
        System.cmd("sh", ["-c", "pkill -f 'claude.*--session-id' 2>/dev/null || true"], stderr_to_stdout: true)
      catch
        _, _ -> :ok
      end

      # Small delay for sessions to terminate cleanly
      Process.sleep(200)

      try do
        Shazam.Company.stop(state.company)
        Formatter.dim("  Company '#{state.company}' stopped")
      catch
        _, _ -> :ok
      end
    end

    try do
      Application.stop(:shazam)
      Formatter.dim("  Server stopped")
    catch
      _, _ -> :ok
    end

    Formatter.success("Goodbye!")
    System.halt(0)
  end

  # ── Event handler ──────────────────────────────────────────

  # Noisy events to suppress from the REPL
  @silent_events ~w(streaming chunk token delta heartbeat ping metrics_updated agent_output tool_use task_checkout)

  defp handle_event(event, state) when is_map(event) do
    type = event[:event] || event["event"]
    type_str = to_string(type)

    # Skip noisy streaming/heartbeat events
    unless type_str in @silent_events do
      tui_exec(state, fn -> Formatter.log_event(event) end)
    end

    # Handle approval requests
    if type in ["task_awaiting_approval", :task_awaiting_approval] do
      task = event[:task] || event["task"] || %{}
      task_id = task["id"] || task[:id]
      title = task["title"] || task[:title] || "?"
      agent = task["assigned_to"] || task[:assigned_to] || "?"

      tui_print(state.tui, [
        IO.ANSI.yellow(), IO.ANSI.bright(),
        "  ⚠  APPROVAL NEEDED", IO.ANSI.reset()])
      tui_print(state.tui, "  Task ##{task_id}: #{title}")
      tui_print(state.tui, "  Agent: #{agent}")
      tui_print(state.tui, [
        IO.ANSI.faint(), "  /approve #{task_id}  or  /reject #{task_id} [reason]",
        IO.ANSI.reset()])

      refresh_chrome(state)
      %{state | pending_approval: [task_id | state.pending_approval]}
    else
      state
    end
  end

  defp handle_event(_event, state), do: state

  # ── Command dispatcher ─────────────────────────────────────

  defp handle_command("/" <> _ = line, state) do
    parts = String.split(line, ~r/\s+/, parts: :infinity)

    case parts do
      ["/exit"] -> :exit
      ["/quit"] -> :exit
      ["/q"] -> :exit

      ["/help"] ->
        tui_exec(state, fn -> print_repl_help() end)
        {:ok, state}

      ["/start"] ->
        if state.running do
          tui_print(state.tui, [IO.ANSI.yellow(), "  Already running. Use /stop first.", IO.ANSI.reset()])
          {:ok, state}
        else
          case boot_agents(state) do
            :ok ->
              refresh_chrome(state)
              {:ok, %{state | running: true}}
            :error ->
              {:ok, state}
          end
        end

      ["/stop"] ->
        if state.running do
          stop_agents(state)
          refresh_chrome(state)
          {:ok, %{state | running: false}}
        else
          tui_print(state.tui, [IO.ANSI.yellow(), "  Not running. Use /start first.", IO.ANSI.reset()])
          {:ok, state}
        end

      ["/status"] ->
        guard_running(state, fn -> cmd_status(state) end)

      ["/agents"] ->
        guard_running(state, fn -> cmd_agents(state) end)

      ["/dashboard"] ->
        guard_running(state, fn -> cmd_dashboard(state) end)

      ["/org"] ->
        guard_running(state, fn -> cmd_org(state) end)

      ["/tasks" | rest] ->
        guard_running(state, fn -> cmd_tasks(rest, state) end)

      ["/task" | rest] ->
        guard_running(state, fn -> cmd_task(rest, state) end)

      ["/approve-all"] ->
        case guard_running(state, fn -> cmd_approve_all(state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: []}}
          other -> other
        end

      ["/aa"] ->
        case guard_running(state, fn -> cmd_approve_all(state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: []}}
          other -> other
        end

      ["/approve" | rest] ->
        case guard_running(state, fn -> cmd_approve(rest, state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: state.pending_approval -- [List.first(rest)]}}
          other -> other
        end

      ["/a" | rest] ->
        case guard_running(state, fn -> cmd_approve(rest, state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: state.pending_approval -- [List.first(rest)]}}
          other -> other
        end

      ["/reject" | rest] ->
        case guard_running(state, fn -> cmd_reject(rest, state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: state.pending_approval -- [List.first(rest)]}}
          other -> other
        end

      ["/r" | rest] ->
        case guard_running(state, fn -> cmd_reject(rest, state) end) do
          {:ok, s} ->
            refresh_chrome(s)
            {:ok, %{s | pending_approval: state.pending_approval -- [List.first(rest)]}}
          other -> other
        end

      ["/msg" | rest] ->
        guard_running(state, fn -> cmd_msg(rest, state) end)

      ["/pause"] ->
        guard_running(state, fn -> cmd_pause(state) end)

      ["/resume"] ->
        guard_running(state, fn -> cmd_resume(state) end)

      ["/auto-approve" | rest] ->
        guard_running(state, fn -> cmd_auto_approve(rest, state) end)

      ["/config"] ->
        tui_exec(state, fn -> cmd_config(state) end)
        {:ok, state}

      ["/clear"] ->
        # Clear scroll region only
        IO.write("\e7")
        for row <- 1..state.tui.scroll_bottom do
          IO.write("\e[#{row};1H\e[2K")
        end
        IO.write("\e8")
        refresh_chrome(state)
        {:ok, state}

      [cmd | _] ->
        tui_exec(state, fn -> suggest_command(cmd) end)
        {:ok, state}
    end
  end

  defp handle_command(line, state) do
    tui_exec(state, fn ->
      Formatter.dim("Commands start with /  — did you mean /#{line}?")
      suggest_command("/" <> line)
    end)
    {:ok, state}
  end

  defp guard_running(state, fun) do
    if state.running do
      tui_exec(state, fun)
      {:ok, state}
    else
      tui_print(state.tui, [IO.ANSI.yellow(), "  Not running. Use /start first.", IO.ANSI.reset()])
      {:ok, state}
    end
  end

  defp stop_agents(state) do
    tui = state.tui

    try do
      Shazam.RalphLoop.pause(state.company)
      tui_print(tui, [IO.ANSI.faint(), "  RalphLoop paused", IO.ANSI.reset()])
    catch
      _, _ -> :ok
    end

    try do
      Shazam.SessionPool.kill_all()
      tui_print(tui, [IO.ANSI.faint(), "  Sessions terminated", IO.ANSI.reset()])
    catch
      _, _ -> :ok
    end

    try do
      Shazam.Company.stop(state.company)
      tui_print(tui, [IO.ANSI.faint(), "  Company stopped", IO.ANSI.reset()])
    catch
      _, _ -> :ok
    end

    tui_print(tui, [IO.ANSI.green(), "  ✓ ", IO.ANSI.reset(), "Agents stopped"])
  end

  # ── Command suggestions ────────────────────────────────────

  defp suggest_command(input) do
    cmd_name = input |> String.split(~r/\s+/) |> List.first() |> String.downcase()

    matches = @commands
      |> Enum.filter(fn {name, _} ->
        String.starts_with?(name, cmd_name) or String.jaro_distance(name, cmd_name) > 0.7
      end)
      |> Enum.sort_by(fn {name, _} -> -String.jaro_distance(name, cmd_name) end)
      |> Enum.take(3)

    case matches do
      [] ->
        Formatter.warning("Unknown command: #{input}")
        Formatter.dim("Type /help for available commands")
      suggestions ->
        Formatter.warning("Unknown command: #{input}")
        IO.puts(["  ", IO.ANSI.faint(), "Did you mean:", IO.ANSI.reset()])
        Enum.each(suggestions, fn {name, desc} ->
          IO.puts(["    ", IO.ANSI.cyan(), name, IO.ANSI.reset(), IO.ANSI.faint(), " — ", desc, IO.ANSI.reset()])
        end)
    end
  end

  # ── Commands ───────────────────────────────────────────────

  defp print_repl_help do
    IO.puts("")
    @commands
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {name, desc} ->
      padded = String.pad_trailing(name, 20)
      IO.puts(["    ", IO.ANSI.cyan(), padded, IO.ANSI.reset(), desc])
    end)
    IO.puts([
      "\n  ", IO.ANSI.faint(),
      "Shortcuts: /a = /approve, /aa = /approve-all, /r = /reject, /q = /exit",
      IO.ANSI.reset(), "\n"
    ])
  end

  defp cmd_status(state) do
    company = state.company

    info = try do
      Shazam.Company.info(company)
    catch
      _, _ -> nil
    end

    ralph_status = try do
      Shazam.RalphLoop.status(company)
    catch
      _, _ -> nil
    end

    IO.puts("")
    if info do
      Formatter.header(info.name)
      IO.puts(["  Mission: ", IO.ANSI.faint(), to_string(info.mission), IO.ANSI.reset()])
      IO.puts([
        "  Status:  ",
        if(info.status == :running, do: [IO.ANSI.green(), "running"], else: [IO.ANSI.yellow(), to_string(info.status)]),
        IO.ANSI.reset()
      ])
      IO.puts(["  Agents:  #{info.agent_count}"])
    else
      Formatter.warning("Company '#{company}' not reachable")
    end

    if ralph_status do
      ralph_state = ralph_status[:state] || "unknown"
      running_count = length(ralph_status[:running_tasks] || [])
      IO.puts([
        "  Ralph:   ",
        if(ralph_state == "running", do: [IO.ANSI.green(), "active"], else: [IO.ANSI.yellow(), to_string(ralph_state)]),
        IO.ANSI.reset(), " (#{running_count} running)"
      ])
      config = ralph_status[:config] || %{}
      auto = if config[:auto_approve], do: "on", else: "off"
      IO.puts(["  Auto-approve: #{auto}"])
    end

    tasks = try do
      TaskBoard.list(%{company: company})
    catch
      _, _ -> []
    end
    if tasks != [] do
      by_status = Enum.group_by(tasks, & &1.status)
      counts = [:pending, :in_progress, :awaiting_approval, :completed, :failed]
        |> Enum.map(fn s -> {s, length(by_status[s] || [])} end)
        |> Enum.filter(fn {_, c} -> c > 0 end)
        |> Enum.map(fn {s, c} -> "#{s}: #{c}" end)
        |> Enum.join("  ")
      IO.puts(["  Tasks:   #{counts}"])
    end
    IO.puts("")
  end

  defp cmd_dashboard(state) do
    agents = try do
      Shazam.Company.agent_statuses(state.company)
    catch
      _, _ -> []
    end

    all_tasks = try do
      TaskBoard.list(%{company: state.company})
    catch
      _, _ -> []
    end

    running_set = try do
      case Shazam.RalphLoop.status(state.company) do
        %{running_tasks: tasks} ->
          tasks |> Enum.map(fn {_id, info} -> info[:agent_name] || info["agent_name"] end) |> MapSet.new()
        _ -> MapSet.new()
      end
    catch
      _, _ -> MapSet.new()
    end

    # Totals
    total = length(all_tasks)
    completed = Enum.count(all_tasks, & &1.status == :completed)
    failed = Enum.count(all_tasks, & &1.status == :failed)
    in_progress = Enum.count(all_tasks, & &1.status in [:running, :in_progress])
    pending = Enum.count(all_tasks, & &1.status == :pending)
    approval = Enum.count(all_tasks, & &1.status == :awaiting_approval)

    IO.puts("")
    IO.puts([IO.ANSI.bright(), "  ─── Dashboard ───", IO.ANSI.reset()])
    IO.puts("")

    # Overall progress bar
    pct = if total > 0, do: round(completed / total * 100), else: 0
    bar_width = 30
    filled = if total > 0, do: round(completed / total * bar_width), else: 0
    empty = bar_width - filled
    bar = [
      IO.ANSI.green(), String.duplicate("█", filled),
      IO.ANSI.faint(), String.duplicate("░", empty),
      IO.ANSI.reset()
    ]
    IO.puts(["  Progress  ", bar, "  #{pct}%  (#{completed}/#{total})"])
    IO.puts([
      "  ",
      IO.ANSI.green(), "✓#{completed}", IO.ANSI.reset(), "  ",
      IO.ANSI.yellow(), "⏳#{in_progress}", IO.ANSI.reset(), "  ",
      IO.ANSI.blue(), "📋#{pending}", IO.ANSI.reset(), "  ",
      IO.ANSI.magenta(), "⚠#{approval}", IO.ANSI.reset(), "  ",
      IO.ANSI.red(), "✗#{failed}", IO.ANSI.reset()
    ])
    IO.puts("")

    # Per-agent breakdown
    Enum.each(agents, fn agent ->
      agent_tasks = Enum.filter(all_tasks, & &1.assigned_to == agent.name)
      a_total = length(agent_tasks)
      a_done = Enum.count(agent_tasks, & &1.status == :completed)
      a_fail = Enum.count(agent_tasks, & &1.status == :failed)
      a_run = Enum.count(agent_tasks, & &1.status in [:running, :in_progress])
      a_pend = Enum.count(agent_tasks, & &1.status in [:pending, :awaiting_approval])

      is_working = MapSet.member?(running_set, agent.name)
      {icon, color} = if is_working, do: {"●", IO.ANSI.green()}, else: {"○", IO.ANSI.faint()}

      # Mini progress bar per agent
      a_pct = if a_total > 0, do: round(a_done / a_total * 100), else: 0
      mini_w = 15
      mini_filled = if a_total > 0, do: round(a_done / a_total * mini_w), else: 0
      mini_empty = mini_w - mini_filled
      mini_bar = [
        IO.ANSI.green(), String.duplicate("█", mini_filled),
        IO.ANSI.faint(), String.duplicate("░", mini_empty),
        IO.ANSI.reset()
      ]

      name_pad = String.pad_trailing(agent.name, 12)
      role_pad = String.pad_trailing("(#{agent.role})", 22)

      IO.puts([
        "  ", color, icon, " ", IO.ANSI.reset(),
        IO.ANSI.bright(), name_pad, IO.ANSI.reset(),
        IO.ANSI.faint(), role_pad, IO.ANSI.reset(),
        mini_bar, "  #{a_pct}%",
        "  ", IO.ANSI.green(), "✓#{a_done}", IO.ANSI.reset(),
        " ", IO.ANSI.yellow(), "⏳#{a_run}", IO.ANSI.reset(),
        " ", IO.ANSI.blue(), "📋#{a_pend}", IO.ANSI.reset(),
        if(a_fail > 0, do: [" ", IO.ANSI.red(), "✗#{a_fail}", IO.ANSI.reset()], else: [])
      ])

      # Show current task if working
      if is_working do
        current = agent_tasks
          |> Enum.find(& &1.status in [:running, :in_progress])
        if current do
          title = String.slice(current.title || "", 0, 50)
          IO.puts(["    ", IO.ANSI.faint(), "└─ ", title, IO.ANSI.reset()])
        end
      end
    end)
    IO.puts("")
  end

  defp cmd_agents(state) do
    agents = try do
      Shazam.Company.agent_statuses(state.company)
    catch
      _, _ -> []
    end

    running = try do
      case Shazam.RalphLoop.status(state.company) do
        %{running_tasks: tasks} -> tasks
        _ -> []
      end
    catch
      _, _ -> []
    end

    running_agents = running
      |> Enum.map(fn {_id, info} -> info[:agent_name] || info["agent_name"] end)
      |> MapSet.new()

    IO.puts("")
    headers = ["Agent", "Role", "Status", "Budget", "Tasks"]
    rows = Enum.map(agents, fn a ->
      status = if MapSet.member?(running_agents, a.name), do: "working", else: "idle"
      budget_str = "#{div(a.tokens_used, 1000)}k/#{div(a.budget, 1000)}k"
      tasks_str = "#{a.tasks_completed}✓ #{a.tasks_in_progress}⏳ #{a.tasks_pending}📋"
      [a.name, a.role, status, budget_str, tasks_str]
    end)
    Formatter.table(headers, rows)
  end

  defp cmd_org(state) do
    chart = try do
      Shazam.Company.org_chart(state.company)
    catch
      _, _ -> []
    end
    IO.puts("")
    Formatter.header("Org Chart — #{state.company}")
    IO.puts("")
    Formatter.tree(normalize_chart(chart))
    IO.puts("")
  end

  defp cmd_tasks(args, state) do
    {opts, positional, _} = OptionParser.parse(args, switches: [clear: :boolean])

    if opts[:clear] do
      case TaskBoard.clear_all() do
        {:ok, count} -> Formatter.success("Cleared #{count} tasks")
        _ -> Formatter.error("Failed to clear tasks")
      end
    else
      filter = List.first(positional) || "active"
      tasks = try do
        TaskBoard.list(%{company: state.company})
      catch
        _, _ -> []
      end

      filtered = case filter do
        "all" -> tasks
        "active" -> Enum.filter(tasks, & &1.status in [:pending, :in_progress, :running, :awaiting_approval])
        "pending" -> Enum.filter(tasks, & &1.status == :pending)
        "running" -> Enum.filter(tasks, & &1.status in [:running, :in_progress])
        "completed" -> Enum.filter(tasks, & &1.status == :completed)
        "failed" -> Enum.filter(tasks, & &1.status == :failed)
        "approval" -> Enum.filter(tasks, & &1.status == :awaiting_approval)
        _ -> tasks
      end

      IO.puts("")
      if filtered == [] do
        Formatter.dim("No #{filter} tasks")
      else
        headers = ["ID", "Title", "Agent", "Status"]
        rows = filtered |> Enum.take(20) |> Enum.map(fn t ->
          [t.id, String.slice(t.title || "", 0, 45), t.assigned_to || "—",
           status_icon(t.status) <> " " <> to_string(t.status)]
        end)
        Formatter.table(headers, rows)
        if length(filtered) > 20, do: Formatter.dim("... and #{length(filtered) - 20} more")
      end
    end
  end

  defp cmd_task(args, state) do
    {opts, positional, _} = OptionParser.parse(args, switches: [to: :string], aliases: [t: :to])
    title = positional |> Enum.join(" ") |> String.trim("\"") |> String.trim("'")

    if title == "" do
      Formatter.warning("Usage: /task \"description\" [--to agent]")
    else
      # Expand paste/image tokens into full content for the description
      description = expand_attachments(title)
      # Keep the title short (without expanded content)
      short_title = Regex.replace(~r/\[Pasted text #\d+ \+\d+ lines\]/, title, "[paste]")
      short_title = Regex.replace(~r/\[Image #\d+\]/, short_title, "[img]")
      short_title = String.slice(short_title, 0, 80)

      attrs = %{title: short_title, description: description, company: state.company}
      attrs = if opts[:to], do: Map.put(attrs, :assigned_to, opts[:to]), else: attrs

      case Shazam.Company.create_task(state.company, attrs) do
        {:ok, task} ->
          Formatter.success("Task ##{task.id} created")
          Formatter.info("\"#{short_title}\"#{if opts[:to], do: " → #{opts[:to]}", else: ""}")
        {:error, reason} ->
          Formatter.error("Failed: #{inspect(reason)}")
      end
    end
  end

  defp cmd_approve_all(state) do
    tasks = try do
      TaskBoard.list(%{company: state.company})
    catch
      _, _ -> []
    end

    awaiting = Enum.filter(tasks, & &1.status == :awaiting_approval)

    if awaiting == [] do
      Formatter.dim("No tasks awaiting approval")
    else
      Enum.each(awaiting, fn task ->
        case TaskBoard.approve(task.id) do
          {:ok, _} -> Formatter.success("Approved ##{task.id} — '#{task.title}'")
          {:error, reason} -> Formatter.warning("##{task.id} skipped: #{inspect(reason)}")
        end
      end)
      Formatter.success("#{length(awaiting)} task(s) approved")
    end
  end

  defp cmd_approve(args, _state) do
    case List.first(args) do
      nil -> Formatter.warning("Usage: /approve <task_id>")
      task_id ->
        case TaskBoard.approve(task_id) do
          {:ok, task} -> Formatter.success("Task ##{task_id} approved — '#{task.title}'")
          {:error, {:not_awaiting_approval, s}} -> Formatter.warning("Task ##{task_id} is #{s}")
          {:error, :not_found} -> Formatter.error("Task ##{task_id} not found")
          {:error, reason} -> Formatter.error("Failed: #{inspect(reason)}")
        end
    end
  end

  defp cmd_reject(args, _state) do
    case List.first(args) do
      nil -> Formatter.warning("Usage: /reject <task_id> [reason]")
      task_id ->
        reason = args |> Enum.drop(1) |> Enum.join(" ")
        reason = if reason == "", do: "Rejected by user", else: reason
        case TaskBoard.reject(task_id, reason) do
          {:ok, _} -> Formatter.success("Task ##{task_id} rejected")
          {:error, {:not_awaiting_approval, s}} -> Formatter.warning("Task ##{task_id} is #{s}")
          {:error, :not_found} -> Formatter.error("Task ##{task_id} not found")
          {:error, err} -> Formatter.error("Failed: #{inspect(err)}")
        end
    end
  end

  defp cmd_msg(args, _state) do
    agent = List.first(args)
    message = args |> Enum.drop(1) |> Enum.join(" ")
    cond do
      is_nil(agent) -> Formatter.warning("Usage: /msg <agent> <message>")
      message == "" -> Formatter.warning("Usage: /msg #{agent} <message>")
      true ->
        case AgentInbox.push(agent, message) do
          :ok ->
            Formatter.success("Message sent to #{agent}")
            spawn(fn -> AgentInbox.execute_pending(agent) end)
          {:error, reason} -> Formatter.error("Failed: #{inspect(reason)}")
        end
    end
  end

  defp cmd_pause(state) do
    case Shazam.RalphLoop.pause(state.company) do
      :ok -> Formatter.success("RalphLoop paused")
      _ -> Formatter.warning("Could not pause")
    end
  end

  defp cmd_resume(state) do
    case Shazam.RalphLoop.resume(state.company) do
      {:ok, _} -> Formatter.success("RalphLoop resumed")
      _ -> Formatter.warning("Could not resume")
    end
  end

  defp cmd_auto_approve(args, state) do
    case List.first(args) do
      "on" ->
        Shazam.RalphLoop.set_auto_approve(state.company, true)
        Formatter.success("Auto-approve enabled")
      "off" ->
        Shazam.RalphLoop.set_auto_approve(state.company, false)
        Formatter.success("Auto-approve disabled")
      _ ->
        config = try do
          s = Shazam.RalphLoop.status(state.company)
          (s[:config] || %{})
        catch
          _, _ -> %{}
        end
        current = config[:auto_approve] || false
        Shazam.RalphLoop.set_auto_approve(state.company, !current)
        Formatter.success("Auto-approve toggled to #{if current, do: "off", else: "on"}")
    end
  end

  defp cmd_config(state) do
    IO.puts("")
    Formatter.header("Configuration")
    IO.puts("  Company:   #{state.company}")
    IO.puts("  Port:      #{state.port}")
    IO.puts("  Workspace: #{Application.get_env(:shazam, :workspace, "?")}")
    agents = try do
      Shazam.Company.get_agents(state.company)
    catch
      _, _ -> []
    end
    IO.puts("  Agents:    #{length(agents)}")
    Enum.each(agents, fn a ->
      IO.puts(["    ", IO.ANSI.faint(), "• ", IO.ANSI.reset(), a.name,
        IO.ANSI.faint(), " (#{a.role}) model=#{a.model || "default"}", IO.ANSI.reset()])
    end)

    # Show tech stack if present
    tech_stack = Application.get_env(:shazam, :tech_stack, nil)
    if tech_stack && is_map(tech_stack) && map_size(tech_stack) > 0 do
      IO.puts("")
      IO.puts([IO.ANSI.bright(), "  Tech Stack", IO.ANSI.reset()])
      Enum.each(tech_stack, fn {key, value} ->
        IO.puts(["    ", IO.ANSI.faint(), "#{key}: ", IO.ANSI.reset(), to_string(value)])
      end)
    end

    IO.puts("")
  end

  # ── Helpers ────────────────────────────────────────────────

  defp status_icon(:pending), do: "📋"
  defp status_icon(:in_progress), do: "⏳"
  defp status_icon(:running), do: "⏳"
  defp status_icon(:completed), do: "✅"
  defp status_icon(:failed), do: "❌"
  defp status_icon(:awaiting_approval), do: "⚠️"
  defp status_icon(:rejected), do: "🚫"
  defp status_icon(:paused), do: "⏸️"
  defp status_icon(_), do: "  "

  defp normalize_chart(nodes) when is_list(nodes) do
    Enum.map(nodes, fn n ->
      %{
        name: n[:name] || n["name"],
        role: n[:role] || n["role"] || "Agent",
        domain: n[:domain] || n["domain"],
        status: n[:status] || n["status"],
        subordinates: normalize_chart(n[:subordinates] || n["subordinates"] || [])
      }
    end)
  end

  defp claude_cli_available? do
    case System.cmd("sh", ["-c", "which claude 2>/dev/null"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp clear_previous_session(company_name) do
    # Stop only the current company's RalphLoop (other projects' loops remain)
    if Code.ensure_loaded?(Shazam.RalphLoop) do
      try do
        if Shazam.RalphLoop.exists?(company_name) do
          Shazam.RalphLoop.stop(company_name)
        end
      catch
        _, _ -> :ok
      end
    end

    # Reset metrics for a fresh session view
    if Code.ensure_loaded?(Shazam.Metrics) do
      try do
        Shazam.Metrics.reset()
      catch
        _, _ -> :ok
      end
    end

    # Restore tasks from .shazam/tasks/ markdown files
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

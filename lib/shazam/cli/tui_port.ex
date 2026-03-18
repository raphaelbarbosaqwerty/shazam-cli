defmodule Shazam.CLI.TuiPort do
  @moduledoc """
  Communicates with the Rust shazam-tui binary via Port.
  Elixir sends JSON render commands; Rust sends user input events.
  """

  alias Shazam.CLI.TuiPort.{Commands, Helpers, Status}

  # ── Public API ────────────────────────────────────────────────

  @doc "Check if the TUI binary is available."
  def available? do
    Helpers.find_tui_binary() != nil
  end

  @doc "Start the TUI port and enter the interactive loop."
  def start(company_state) do
    tui_path = Helpers.find_tui_binary()

    case tui_path do
      nil ->
        IO.puts("Error: shazam-tui binary not found. Run `cargo build --release` in shazam-tui/")
        System.halt(1)

      path ->
        # nouse_stdio: child keeps stdin/stdout for terminal (ratatui),
        # uses fd 3/4 for JSON protocol with Elixir
        port = Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          {:line, 16_384},
          :nouse_stdio
        ])

        # Trap exits for graceful shutdown
        Process.flag(:trap_exit, true)

        state = %{
          port: port,
          company: company_state,
          paste_store: %{},
          image_store: %{}
        }

        # Send initial status
        Status.send_status(state)

        # Send welcome event
        Helpers.send_event(port, "system", "info",
          "Welcome to #{company_state[:name] || "Shazam"}. Type /start to boot agents, /help for commands.")

        # Subscribe to EventBus if available
        if Code.ensure_loaded?(Shazam.API.EventBus) do
          try do
            Shazam.API.EventBus.subscribe()
          rescue
            _ -> :ok
          end
        end

        # Enter event loop
        loop(state)
    end
  end

  # ── Event Loop ────────────────────────────────────────────────

  defp loop(state) do
    receive do
      # Data from Rust TUI (user input)
      {port, {:data, {:eol, json}}} when port == state.port ->
        case Jason.decode(json) do
          {:ok, msg} ->
            state = handle_tui_message(msg, state)
            loop(state)

          {:error, _} ->
            loop(state)
        end

      # Port closed — only cleanup path (no duplicate)
      {port, {:exit_status, _code}} when port == state.port ->
        Helpers.cleanup(state)

      # EventBus events from agents/ralph
      {:event, event} ->
        handle_backend_event(event, state)
        loop(state)

      # Graceful shutdown (linked process died or Ctrl+C from outside)
      {:EXIT, _pid, _reason} ->
        try do
          Helpers.send_json(state.port, %{type: "quit"})
          Process.sleep(100)
        catch
          _, _ -> :ok
        end
        # Don't call cleanup here — the Port exit_status message will handle it.
        # Just wait for the exit_status message to arrive.
        receive do
          {port, {:exit_status, _}} when port == state.port -> :ok
        after
          500 -> :ok
        end
        Helpers.cleanup(state)

      _other ->
        loop(state)
    end
  end

  # ── Handle messages FROM Rust TUI ────────────────────────────

  defp handle_tui_message(%{"type" => "command", "raw" => raw}, state) do
    Commands.handle_command(String.trim(raw), state)
  end

  defp handle_tui_message(%{"type" => "paste", "content" => content, "line_count" => count}, state) do
    id = map_size(state.paste_store) + 1
    %{state | paste_store: Map.put(state.paste_store, id, %{content: content, lines: count})}
  end

  defp handle_tui_message(%{"type" => "image", "path" => path}, state) do
    id = map_size(state.image_store) + 1
    %{state | image_store: Map.put(state.image_store, id, path)}
  end

  defp handle_tui_message(%{"type" => "resize"}, state) do
    # No action needed — Rust handles its own resize
    state
  end

  defp handle_tui_message(_msg, state), do: state

  # ── Backend Event Handler ─────────────────────────────────────

  @silent_events ~w(streaming chunk token delta heartbeat ping metrics_updated agent_output modules_claimed)

  defp handle_backend_event(event, state) do
    event_type = event[:event] || event["event"] || "unknown"

    unless event_type in @silent_events do
      task_id = event[:task_id] || event["task_id"]

      # Resolve agent and title from TaskBoard if not provided
      {agent, title} = resolve_event_details(event, task_id)

      # Skip events with no useful info
      unless agent == "" and title == "" do
        Helpers.send_event(state.port, agent, event_type, to_string(title))
      end

      # If it's an approval request, also send approval message
      if event_type == "task_awaiting_approval" do
        Helpers.send_json(state.port, %{
          type: "approval",
          task_id: task_id || "",
          title: to_string(title),
          agent: agent,
          description: event[:description] || event["description"]
        })
      end
    end

    # Update status on relevant events
    if event_type in ~w(task_created task_completed task_failed task_started task_approved task_rejected ralph_resumed ralph_paused task_killed task_paused task_resumed) do
      Status.send_status(state)
    end
  end

  defp resolve_event_details(event, task_id) do
    raw_agent = event[:agent] || event["agent"] || event["assigned_to"] || ""
    raw_title = event[:title] || event["title"] || ""
    raw_text = event[:text] || event["text"] || ""

    # If we have a task_id but missing agent/title, look it up
    if task_id && (raw_agent == "" or raw_title == "") do
      task_info = try do
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          case Shazam.TaskBoard.get(task_id) do
            {:ok, t} -> t
            _ -> nil
          end
        end
      catch
        _, _ -> nil
      end

      agent = if raw_agent == "" and task_info, do: task_info.assigned_to || "system", else: raw_agent
      title = cond do
        raw_title != "" -> raw_title
        raw_text != "" -> raw_text
        task_info -> "#{task_id}: #{task_info.title || ""}"
        true -> to_string(task_id)
      end

      {to_string(agent), title}
    else
      title = if raw_title != "", do: raw_title, else: raw_text
      {to_string(raw_agent), title}
    end
  end
end

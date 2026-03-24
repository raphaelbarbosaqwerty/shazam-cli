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

        # Give TUI binary time to initialize before sending data
        Process.sleep(100)

        # Send initial status
        try do
          Status.send_status(state)
        catch
          _, _ -> :ok
        end

        # Send welcome event
        try do
          Helpers.send_event(port, "system", "info",
            "Welcome to #{company_state[:name] || "Shazam"}. Type /start to boot agents, /help for commands.")
        catch
          _, _ -> :ok
        end

        # Subscribe to EventBus if available
        if Code.ensure_loaded?(Shazam.API.EventBus) do
          try do
            Shazam.API.EventBus.subscribe()
          rescue
            _ -> :ok
          end
        end

        # Send initial status
        Status.send_status(state)

        # Enter event loop
        loop(state)
    end
  end

  # ── Event Loop ────────────────────────────────────────────────

  defp loop(state) do
    try do
      receive do
        # Data from Rust TUI (user input)
        {port, {:data, {:eol, json}}} when port == state.port ->
          case Jason.decode(json) do
            {:ok, msg} ->
              new_state = try do
                handle_tui_message(msg, state)
              rescue
                e ->
                  log_crash("handle_tui_message rescue", e, __STACKTRACE__)
                  try_send_error(state, inspect(e))
                  state
              catch
                kind, reason ->
                  log_crash("handle_tui_message #{kind}", reason)
                  try_send_error(state, inspect(reason))
                  state
              end
              loop(new_state)

            {:error, _} ->
              loop(state)
          end

        # Port closed (TUI exited)
        {port, {:exit_status, _code}} when port == state.port ->
          Helpers.shutdown(state)

        # EventBus events from agents/ralph
        {:event, event} ->
          try do
            handle_backend_event(event, state)
          rescue
            e -> log_crash("backend_event rescue", e, __STACKTRACE__)
          catch
            _, reason -> log_crash("backend_event catch", reason)
          end
          loop(state)

        # Ignore normal exits from spawned processes
        {:EXIT, _pid, :normal} ->
          loop(state)

        # Graceful shutdown (linked process died abnormally or Ctrl+C)
        {:EXIT, _pid, reason} ->
          log_crash("EXIT signal", reason)
          try do
            Helpers.send_json(state.port, %{type: "quit"})
            Process.sleep(100)
          catch
            _, _ -> :ok
          end
          receive do
            {port, {:exit_status, _}} when port == state.port -> :ok
          after
            500 -> :ok
          end
          Helpers.shutdown(state)

        _other ->
          loop(state)
      end
    rescue
      e ->
        log_crash("loop rescue", e, __STACKTRACE__)
        try_send_error(state, inspect(e))
        loop(state)
    catch
      kind, reason ->
        log_crash("loop #{kind}", reason)
        try_send_error(state, inspect(reason))
        loop(state)
    end
  end

  defp log_crash(context, error, stacktrace \\ nil) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
    trace = if stacktrace, do: "\n#{Exception.format_stacktrace(stacktrace)}", else: ""
    entry = "[#{timestamp}] #{context}: #{inspect(error, limit: 500)}#{trace}\n\n"
    File.write("/tmp/shazam-crash.log", entry, [:append])
  end

  defp try_send_error(state, message) do
    try do
      Helpers.send_event(state.port, "system", "error", "Error: #{String.slice(message, 0..200)}")
    catch
      _, _ -> :ok
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

  @silent_events ~w(streaming chunk token delta heartbeat ping metrics_updated modules_claimed)

  defp handle_backend_event(event, state) do
    event_type = event[:event] || event["event"] || "unknown"

    unless event_type in @silent_events do
      task_id = event[:task_id] || event["task_id"]

      cond do
      # Show skip reason clearly
      event_type == "task_skipped" ->
        agent = event[:agent] || event["agent"] || ""
        reason = event[:reason] || event["reason"] || "unknown reason"
        task_id_val = event[:task_id] || event["task_id"] || ""
        Helpers.send_event(state.port, agent, "task_skipped", "#{task_id_val}: #{reason}")

      # Handle agent_output specially — show tool_use and text, skip text_delta
      event_type == "agent_output" ->
        agent = event[:agent] || event["agent"] || ""
        output_type = event[:type] || event["type"] || ""
        content = event[:content] || event["content"] || ""

        case output_type do
          "tool_use" ->
            # Show which tool the agent is using (truncated)
            Helpers.send_event(state.port, agent, "tool_use", String.slice(to_string(content), 0..120))
          "text" ->
            # Show agent thinking/output (first line only)
            first_line = content |> to_string() |> String.split("\n") |> List.first("")
            if String.length(first_line) > 5 do
              Helpers.send_event(state.port, agent, "agent_output", String.slice(first_line, 0..120))
            end
          _ ->
            # Skip text_delta and other noisy types
            :ok
        end

      # All other events
      true ->
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
    end

    # Auto-save plans from completed planning tasks
    if event_type == "task_completed" do
      try do
        task_id_val = event[:task_id] || event["task_id"]
        if task_id_val do
          case Shazam.TaskBoard.get(task_id_val) do
            {:ok, task} when task.created_by == "human" ->
              if String.starts_with?(task.title || "", "Create plan:") and is_binary(task.result) do
                plan_id_match = Regex.run(~r/Plan ID: (plan_\d+)/, task.description || "")
                plan_id = case plan_id_match do
                  [_, id] -> id
                  _ -> Shazam.PlanManager.next_id()
                end

                case Shazam.PlanManager.parse_plan_from_output(plan_id, task.result) do
                  {:ok, plan} ->
                    Shazam.PlanManager.save_plan(plan)
                    Helpers.send_event(state.port, "system", "info",
                      "Plan '#{plan.title}' saved as #{plan_id}. Review: /plan --show #{plan_id} | Approve: /plan --approve #{plan_id}")
                  _ -> :ok
                end
              end
            _ -> :ok
          end
        end
      catch
        _, _ -> :ok
      end
    end

    # Auto-generate QA docs for completed dev tasks
    if event_type == "task_completed" and Application.get_env(:shazam, :qa_auto, false) do
      try do
        task_id_val = event[:task_id] || event["task_id"]
        if task_id_val do
          case Shazam.TaskBoard.get(task_id_val) do
            {:ok, task} ->
              # Only for dev tasks (not PM planning, not QA validation, not reviews)
              created_by = task.created_by || ""
              title = task.title || ""
              is_dev_task = not String.starts_with?(title, "Create plan:") and
                            not String.starts_with?(title, "QA Validate:") and
                            not String.starts_with?(title, "Review PR") and
                            not String.starts_with?(title, "Update project memory") and
                            created_by != "qa_system"

              if is_dev_task do
                case Shazam.QAManager.generate_qa_doc(task) do
                  {:ok, _path} ->
                    Helpers.send_event(state.port, "system", "info", "QA doc auto-generated for #{task_id_val}")
                  _ -> :ok
                end
              end
            _ -> :ok
          end
        end
      catch
        _, _ -> :ok
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

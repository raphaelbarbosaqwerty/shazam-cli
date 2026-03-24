defmodule Shazam.CLI.TuiPort.Commands.Tasks do
  @moduledoc """
  Task commands: /tasks, /task, /approve, /approve-all, /aa, /reject, /search,
  /export, /pause-task, /resume-task, /kill-task, /retry-task, /delete-task,
  /start-task, /msg, /auto-approve, and the catch-all for plain text (creating tasks).
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/tasks" <> rest, state) do
    args = String.trim(rest)
    cond do
      args == "--sync" ->
        # Import tasks from .shazam/tasks/ files
        imported = Shazam.TaskFiles.read_all()
        new_count = Enum.count(imported, fn t ->
          case Shazam.TaskBoard.get(t.id) do
            {:ok, _} -> false
            _ -> true
          end
        end)
        Shazam.TaskFiles.sync_from_files()
        Helpers.send_event(state.port, "system", "info", "Synced #{length(imported)} tasks from .shazam/tasks/ (#{new_count} new)")
        Status.send_status(state)

      args == "--export" ->
        tasks = Helpers.list_tasks(state)
        Shazam.TaskFiles.sync_to_files(tasks)
        Helpers.send_event(state.port, "system", "info", "Exported #{length(tasks)} tasks to .shazam/tasks/")

      args == "--clear" ->
        if Code.ensure_loaded?(Shazam.TaskBoard) do
          tasks = Helpers.list_tasks(state)
          Enum.each(tasks, fn t -> Shazam.TaskBoard.delete(t.id) end)
        end
        Helpers.send_event(state.port, "system", "tasks_cleared", "All tasks cleared")
        Status.send_status(state)

      true ->
        tasks = Helpers.list_tasks(state)
        task_items = Enum.map(tasks, fn t ->
          %{
            id: t.id,
            title: t.title || "",
            status: to_string(t.status),
            assigned_to: t.assigned_to,
            created_by: t.created_by,
            created_at: format_task_time(t),
            result: if(is_binary(t.result), do: String.slice(t.result, 0..500), else: nil)
          }
        end)
        Helpers.send_json(state.port, %{type: "task_list", tasks: task_items})
    end
    state
  end

  def handle_command("/task " <> title, state) do
    title = Helpers.expand_attachments(title, state)
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: title,
        created_by: "human",
        assigned_to: pm_name,
        priority: "normal",
        company: company_name
      })
      Helpers.send_event(state.port, pm_name, "task_created", title)
    end
    Status.send_status(state)
    state
  end

  def handle_command("/approve " <> task_id, state) do
    Helpers.approve_task(String.trim(task_id), state)
    Status.send_status(state)
    state
  end

  def handle_command("/reject " <> task_id, state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.reject(String.trim(task_id))
    end
    Status.send_status(state)
    state
  end

  def handle_command("/approve-all", state) do
    Helpers.approve_all(state)
    Helpers.send_json(state.port, %{type: "clear_approvals"})
    Status.send_status(state)
    state
  end

  def handle_command("/aa", state) do
    Helpers.approve_all(state)
    Helpers.send_json(state.port, %{type: "clear_approvals"})
    Status.send_status(state)
    state
  end

  def handle_command("/msg " <> rest, state) do
    case String.split(rest, " ", parts: 2) do
      [agent, message] ->
        if Code.ensure_loaded?(Shazam.AgentInbox) do
          Shazam.AgentInbox.push(String.trim(agent), %{
            from: "human",
            content: String.trim(message)
          })
          Helpers.send_event(state.port, agent, "message_sent", "Message sent to #{agent}")
        end
      _ ->
        Helpers.send_event(state.port, "system", "error", "Usage: /msg <agent> <message>")
    end
    state
  end

  def handle_command("/auto-approve" <> rest, state) do
    company_name = state.company[:name] || state.company.name
    arg = String.trim(rest)
    cond do
      arg in ["on", "true", "yes"] ->
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          Shazam.RalphLoop.set_auto_approve(company_name, true)
          Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: ON")
          Helpers.send_event(state.port, "system", "info", "(session only — add `auto_approve: true` to shazam.yaml to persist)")
        end
      arg in ["off", "false", "no"] ->
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          Shazam.RalphLoop.set_auto_approve(company_name, false)
          Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: OFF")
          Helpers.send_event(state.port, "system", "info", "(session only — add `auto_approve: false` to shazam.yaml to persist)")
        end
      true ->
        # Toggle
        if Code.ensure_loaded?(Shazam.RalphLoop) do
          case Shazam.RalphLoop.status(company_name) do
            %{auto_approve: current} ->
              new_val = !current
              Shazam.RalphLoop.set_auto_approve(company_name, new_val)
              Helpers.send_event(state.port, "system", "config_changed", "Auto-approve: #{if new_val, do: "ON", else: "OFF"}")
              Helpers.send_event(state.port, "system", "info", "(session only — update shazam.yaml to persist)")
            _ ->
              Helpers.send_event(state.port, "system", "info", "Start agents first with /start")
          end
        end
    end
    state
  catch
    :exit, _ -> state
    _, _ -> state
  end

  def handle_command("/pause-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.pause_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_paused", "Task paused: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot pause: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.pause(task_id)
      Helpers.send_event(state.port, "system", "task_paused", "Task paused: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/resume-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.resume_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_resumed", "Task resumed: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot resume: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.resume_task(task_id)
      Helpers.send_event(state.port, "system", "task_resumed", "Task resumed: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/kill-task " <> task_id, state) do
    task_id = String.trim(task_id)
    company_name = Helpers.deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.RalphLoop) and Shazam.RalphLoop.exists?(company_name) do
      case Shazam.RalphLoop.kill_task(company_name, task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_killed", "Task killed: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot kill: #{inspect(reason)}")
      end
    else
      if Code.ensure_loaded?(Shazam.TaskBoard), do: Shazam.TaskBoard.fail(task_id, "Killed by user")
      Helpers.send_event(state.port, "system", "task_killed", "Task killed: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/retry-task " <> task_id, state) do
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      case Shazam.TaskBoard.retry(task_id) do
        {:ok, _} -> Helpers.send_event(state.port, "system", "task_resumed", "Task retrying: #{task_id}")
        {:error, reason} -> Helpers.send_event(state.port, "system", "error", "Cannot retry: #{inspect(reason)}")
      end
    end
    Status.send_status(state)
    state
  end

  def handle_command("/retry-all", state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      tasks = Helpers.list_tasks(state)
      failed = Enum.filter(tasks, &(&1.status in [:failed, :error]))
      Enum.each(failed, fn t ->
        try do
          Shazam.TaskBoard.retry(t.id)
        catch
          _, _ -> :ok
        end
      end)
      Helpers.send_event(state.port, "system", "info", "Retrying #{length(failed)} failed task(s)")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/delete-task " <> task_id, state) do
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.delete(task_id)
      Helpers.send_event(state.port, "system", "task_deleted", "Task deleted: #{task_id}")
    end
    Status.send_status(state)
    state
  end

  def handle_command("/start-task " <> task_id, state) do
    # Just ensure it's pending so RalphLoop picks it up
    task_id = String.trim(task_id)
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      case Shazam.TaskBoard.get(task_id) do
        {:ok, task} ->
          if task.status in [:paused, :failed, :rejected] do
            Shazam.TaskBoard.retry(task_id)
          end
          Helpers.send_event(state.port, "system", "info", "Task queued: #{task_id}")
        _ ->
          Helpers.send_event(state.port, "system", "error", "Task not found: #{task_id}")
      end
    end
    Status.send_status(state)
    state
  end

  def handle_command("/search " <> query, state) do
    query = String.trim(query)
    tasks = Helpers.list_tasks(state)
    matches = Enum.filter(tasks, fn t ->
      String.contains?(String.downcase(t.title || ""), String.downcase(query))
    end)
    task_items = Enum.map(matches, fn t ->
      %{
        id: t.id,
        title: t.title || "",
        status: to_string(t.status),
        assigned_to: t.assigned_to,
        created_by: t.created_by,
        created_at: format_task_time(t),
        result: if(is_binary(t.result), do: String.slice(t.result, 0..500), else: nil)
      }
    end)
    Helpers.send_json(state.port, %{type: "task_list", tasks: task_items})
    state
  end

  def handle_command("/export" <> rest, state) do
    filename = case String.trim(rest) do
      "" -> "shazam-export-#{Date.to_string(Date.utc_today())}.md"
      name -> name
    end
    tasks = Helpers.list_tasks(state)
    content = Enum.map_join(tasks, "\n\n---\n\n", fn t ->
      status = to_string(t.status)
      agent = t.assigned_to || "unassigned"
      result = if is_binary(t.result), do: "\n\n#{t.result}", else: ""
      "## #{t.title}\n\n**Status:** #{status} | **Agent:** #{agent} | **ID:** #{t.id}#{result}"
    end)
    header = "# Shazam Export — #{Date.to_string(Date.utc_today())}\n\n"
    File.write!(filename, header <> content)
    Helpers.send_event(state.port, "system", "info", "Exported #{length(tasks)} tasks to #{filename}")
    state
  end

  # Natural language → task for PM
  def handle_command(text, state) when text != "" do
    title = Helpers.expand_attachments(text, state)
    company_name = Helpers.deep_get(state, [:company, :name])
    pm_name = Helpers.find_pm_name(state)

    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.create(%{
        title: title,
        created_by: "human",
        assigned_to: pm_name,
        priority: "normal",
        company: company_name
      })
      Helpers.send_event(state.port, pm_name, "task_created", title)
    end
    Status.send_status(state)
    state
  end

  defp format_task_time(task) do
    cond do
      is_struct(task[:created_at], DateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      is_struct(task[:created_at], NaiveDateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      is_binary(task[:created_at]) ->
        task.created_at
      Map.has_key?(task, :created_at) and is_struct(task.created_at, DateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      Map.has_key?(task, :created_at) and is_struct(task.created_at, NaiveDateTime) ->
        Calendar.strftime(task.created_at, "%H:%M:%S")
      true ->
        ""
    end
  end
end

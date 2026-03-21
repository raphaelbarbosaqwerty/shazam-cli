defmodule Shazam.CLI.TuiPort.Helpers do
  @moduledoc """
  Utility functions for TuiPort: JSON transport, formatting, attachments, approvals.
  """

  def send_json(port, data) do
    json = Jason.encode!(data)
    Port.command(port, json <> "\n")
  end

  def send_event(port, agent, event_type, title) do
    send_json(port, %{
      type: "event",
      agent: agent,
      event: event_type,
      title: title,
      timestamp: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    })
  end

  def expand_attachments(text, state) do
    text
    |> expand_paste_tokens(state.paste_store)
    |> expand_image_tokens(state.image_store)
    |> expand_file_mentions()
  end

  def expand_paste_tokens(text, store) do
    Regex.replace(~r/\[Pasted text #(\d+) \+\d+ lines\]/, text, fn _, id_str ->
      id = String.to_integer(id_str)
      case Map.get(store, id) do
        %{content: content} -> "\n```\n#{content}\n```\n"
        _ -> "[paste not found]"
      end
    end)
  end

  def expand_image_tokens(text, store) do
    Regex.replace(~r/\[Image #(\d+)\]/, text, fn _, id_str ->
      id = String.to_integer(id_str)
      case Map.get(store, id) do
        path when is_binary(path) ->
          # Copy to .shazam/attachments/ for persistence
          workspace = Application.get_env(:shazam, :workspace, File.cwd!())
          attachments_dir = Path.join(workspace, ".shazam/attachments")
          File.mkdir_p!(attachments_dir)

          filename = "image_#{id}_#{Path.basename(path)}"
          dest = Path.join(attachments_dir, filename)

          case File.cp(path, dest) do
            :ok -> "[image:#{dest}]"
            _ -> "[image:#{path}]"
          end
        _ -> "[image not found]"
      end
    end)
  end

  def expand_file_mentions(text) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    Regex.replace(~r/@([\w\.\-\/]+)/, text, fn full_match, path ->
      full_path = Path.join(workspace, path)
      cond do
        File.regular?(full_path) ->
          content = File.read!(full_path)
          # Truncate large files to 3000 chars
          truncated = String.slice(content, 0..3000)
          "\n\n**File: #{path}**\n```\n#{truncated}\n```\n"
        File.dir?(full_path) ->
          files = File.ls!(full_path) |> Enum.take(20) |> Enum.join(", ")
          "\n\n**Directory: #{path}** — #{files}\n"
        true ->
          full_match  # Keep as-is if not found
      end
    end)
  end

  def format_config(state) do
    company = state.company || %{}
    name = company[:name] || "N/A"
    mission = company[:mission] || "N/A"
    agents = company[:agents] || []
    "Company: #{name} | Mission: #{mission} | Agents: #{length(agents)}"
  end

  def format_org_tree(agents) do
    agents
    |> Enum.map(fn a -> "#{safe_field(a, :name, "?")} (#{safe_field(a, :role, "")})" end)
    |> Enum.join(" → ")
  end

  @tui_binary "shazam-tui"

  def find_tui_binary do
    # 1. Next to the running executable (Burrito standalone or escript)
    self_dir = case :init.get_argument(:progname) do
      {:ok, [[progname]]} -> Path.dirname(to_string(progname))
      _ -> nil
    end
    # Also check next to System argv0
    argv0_dir = case System.argv() do
      _ ->
        case System.find_executable("shazam-cli") || System.find_executable("shazam") do
          nil -> self_dir
          path -> Path.dirname(path)
        end
    end

    sibling_path = if argv0_dir, do: Path.join(argv0_dir, @tui_binary)

    # 2. Check priv/ in the OTP release
    priv_path = case :code.priv_dir(:shazam) do
      {:error, _} -> nil
      dir -> Path.join(to_string(dir), @tui_binary)
    end

    # 3. Check relative to project (dev mode)
    project_path = Path.join(["priv", @tui_binary])

    # 4. Check shazam-tui/target/release (dev build)
    dev_build_path = Path.join(["shazam-tui", "target", "release", @tui_binary])

    # 5. Check in PATH
    system_path = System.find_executable(@tui_binary)

    # 6. Check next to Burrito cache (extracted release)
    burrito_path = case System.get_env("BURRITO_CACHE_DIR") do
      nil -> nil
      dir -> Path.join(dir, @tui_binary)
    end

    cond do
      sibling_path && File.exists?(sibling_path) -> sibling_path
      priv_path && File.exists?(priv_path) -> priv_path
      burrito_path && File.exists?(burrito_path) -> burrito_path
      File.exists?(project_path) -> Path.expand(project_path)
      File.exists?(dev_build_path) -> Path.expand(dev_build_path)
      system_path -> system_path
      true -> nil
    end
  end

  def deep_get(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => val} -> {:cont, val}
        _ -> {:halt, nil}
      end
    end)
  end
  def deep_get(_, _), do: nil

  def get_agent_status(name) do
    if Code.ensure_loaded?(Shazam.Metrics) do
      case Shazam.Metrics.get_agent(name) do
        %{status: s} when is_binary(s) -> s
        _ -> "idle"
      end
    else
      "idle"
    end
  catch
    :exit, _ -> "idle"
    _, _ -> "idle"
  end

  def cleanup(state) do
    try do
      Port.close(state.port)
    catch
      _, _ -> :ok
    end
  end

  def shutdown(state) do
    cleanup(state)
    # Stop all OTP processes before exiting
    try do
      Application.stop(:shazam)
    catch
      _, _ -> :ok
    end
    IO.puts("\nShazam session ended.")
    System.halt(0)
  end

  def find_pm_name(state) do
    agents = deep_get(state, [:company, :agents]) ||
             deep_get(state, [:company, :config, :agents]) || []
    # Find the top of hierarchy: first agent without a supervisor (Engineering Manager or PM)
    case Enum.find(agents, fn a ->
      role = String.downcase(to_string(safe_field(a, :role, "")))
      supervisor = safe_field(a, :supervisor, nil)
      (String.contains?(role, "manager") or String.contains?(role, "pm")) and supervisor == nil
    end) do
      nil ->
        # Fallback: any agent with "manager" or "pm" in role
        case Enum.find(agents, fn a ->
          role = String.downcase(to_string(safe_field(a, :role, "")))
          String.contains?(role, "manager") or String.contains?(role, "pm")
        end) do
          nil -> safe_field(Enum.at(agents, 0, %{}), :name, "pm")
          agent -> safe_field(agent, :name, "pm")
        end
      agent -> safe_field(agent, :name, "pm")
    end
  end

  # Safe field access for both structs and maps
  defp safe_field(nil, _key, default), do: default
  defp safe_field(item, key, default) when is_struct(item), do: Map.get(item, key, default)
  defp safe_field(item, key, default) when is_map(item), do: item[key] || Map.get(item, key, default)
  defp safe_field(_, _key, default), do: default

  def list_tasks(state) do
    company_name = deep_get(state, [:company, :name])
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      if company_name do
        Shazam.TaskBoard.list(%{company: company_name})
      else
        Shazam.TaskBoard.list()
      end
    else
      []
    end
  rescue
    _ -> []
  end

  def approve_all(state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      tasks = list_tasks(state)
      pending = Enum.filter(tasks, &(to_string(&1.status) == "awaiting_approval"))
      Enum.each(pending, fn t ->
        Shazam.TaskBoard.approve(t.id)
        send_event(state.port, t.assigned_to || "system", "task_approved", t.title)
      end)
    end
  end

  def approve_task(task_id, state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      Shazam.TaskBoard.approve(String.trim(task_id))
      send_event(state.port, "system", "task_approved", task_id)
    end
  end

  def approve_next(state) do
    if Code.ensure_loaded?(Shazam.TaskBoard) do
      tasks = list_tasks(state)
      case Enum.find(tasks, &(to_string(&1.status) == "awaiting_approval")) do
        nil ->
          send_event(state.port, "system", "info", "No tasks awaiting approval")
        t ->
          Shazam.TaskBoard.approve(t.id)
          send_event(state.port, t.assigned_to || "system", "task_approved", t.title)
      end
    end
  end
end

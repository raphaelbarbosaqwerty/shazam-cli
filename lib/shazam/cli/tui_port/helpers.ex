defmodule Shazam.CLI.TuiPort.Helpers do
  @moduledoc """
  Utility functions for TuiPort: JSON transport, formatting, attachments, approvals.
  """

  def send_json(port, data) do
    json = Jason.encode!(data)
    Port.command(port, json <> "\n")
  rescue
    ArgumentError -> :port_closed
  catch
    _, _ -> :port_closed
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
        path when is_binary(path) -> "[image:#{path}]"
        _ -> "[image not found]"
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
    |> Enum.map(fn a -> "#{a[:name]} (#{a[:role]})" end)
    |> Enum.join(" → ")
  end

  @tui_binary "shazam-tui"

  def find_tui_binary do
    # 1. Next to the escript that is actually running (not macOS /usr/bin/shazam)
    self_dir = case :init.get_argument(:progname) do
      {:ok, [[progname]]} -> Path.dirname(to_string(progname))
      _ -> nil
    end

    argv0_dir = case System.find_executable("shazam") do
      nil -> self_dir
      path ->
        dir = Path.dirname(path)
        # Skip macOS system ShazamKit at /usr/bin/shazam
        if dir == "/usr/bin", do: self_dir, else: dir
    end

    sibling_path = if argv0_dir, do: Path.join(argv0_dir, @tui_binary)

    # 2. Check ~/bin (default install location from build.sh)
    home_bin_path = Path.expand("~/bin/#{@tui_binary}")

    # 3. Check priv/ in the OTP release
    priv_path = case :code.priv_dir(:shazam) do
      {:error, _} -> nil
      dir -> Path.join(to_string(dir), @tui_binary)
    end

    # 4. Check relative to project (dev mode)
    project_path = Path.join(["priv", @tui_binary])

    # 5. Check shazam-tui/target/release (dev build)
    dev_build_path = Path.join(["shazam-tui", "target", "release", @tui_binary])

    # 6. Check in PATH
    system_path = System.find_executable(@tui_binary)

    # 7. Check next to Burrito cache (extracted release)
    burrito_path = case System.get_env("BURRITO_CACHE_DIR") do
      nil -> nil
      dir -> Path.join(dir, @tui_binary)
    end

    cond do
      sibling_path && File.exists?(sibling_path) -> sibling_path
      File.exists?(home_bin_path) -> home_bin_path
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
    IO.puts("\nShazam session ended.")
  end

  def find_pm_name(state) do
    agents = deep_get(state, [:company, :agents]) ||
             deep_get(state, [:company, :config, :agents]) || []
    case Enum.find(agents, fn a ->
      role = String.downcase(a[:role] || "")
      String.contains?(role, "manager") or String.contains?(role, "pm")
    end) do
      nil -> Enum.at(agents, 0, %{})[:name] || "pm"
      agent -> agent[:name]
    end
  end

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

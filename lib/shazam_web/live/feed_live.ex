defmodule ShazamWeb.FeedLive do
  use ShazamWeb, :live_view

  @max_events 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      try do
        Shazam.API.EventBus.subscribe()
      catch
        _, _ -> :ok
      end
    end

    {company_name, status, agent_count} = load_header_info()

    {:ok,
     assign(socket,
       page_title: "Feed",
       events: [],
       company_name: company_name,
       system_status: status,
       agent_count: agent_count,
       command_input: ""
     )}
  end

  @impl true
  def handle_info({:event, event}, socket) do
    new_event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      type: get_field(event, :event) || get_in_safe(event, [:event]) || "unknown",
      agent: get_in_safe(event, [:task, :assigned_to]) || get_field(event, :agent) || "system",
      content: format_event_content(event)
    }

    events =
      [new_event | socket.assigns.events]
      |> Enum.take(@max_events)

    {company_name, status, agent_count} = load_header_info()

    {:noreply,
     assign(socket,
       events: events,
       company_name: company_name,
       system_status: status,
       agent_count: agent_count
     )}
  end

  @impl true
  def handle_event("submit_command", %{"command" => command}, socket) when command != "" do
    try do
      {company_name, pm_name} = detect_company_and_pm()

      Shazam.TaskBoard.create(%{
        title: command,
        created_by: "web_ui",
        assigned_to: pm_name,
        company: company_name
      })
    catch
      _, _ -> :ok
    end

    {:noreply, assign(socket, command_input: "")}
  end

  def handle_event("submit_command", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full -m-6 -mt-4">
      <%!-- Top bar --%>
      <div class="px-6 py-3 bg-zinc-900 border-b border-zinc-800 flex items-center justify-between">
        <div class="flex items-center gap-4">
          <h2 class="text-lg font-bold text-zinc-100">{@company_name}</h2>
          <span class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium #{status_color(@system_status)}"}>
            <span class={"w-1.5 h-1.5 rounded-full #{status_dot(@system_status)}"}></span>
            {String.capitalize(@system_status)}
          </span>
        </div>
        <div class="text-sm text-zinc-400">
          {@agent_count} agent(s)
        </div>
      </div>

      <%!-- Event feed --%>
      <div class="flex-1 overflow-y-auto p-4 space-y-1" id="event-feed" phx-hook="AutoScroll">
        <div :if={@events == []} class="flex items-center justify-center h-full">
          <p class="text-zinc-500 text-sm">No events yet. Waiting for activity...</p>
        </div>
        <div
          :for={event <- Enum.reverse(@events)}
          class="flex items-start gap-3 px-3 py-2 rounded-lg hover:bg-zinc-900/50 transition-colors group"
        >
          <span class="text-xs text-zinc-600 font-mono shrink-0 mt-0.5">
            {Calendar.strftime(event.timestamp, "%H:%M:%S")}
          </span>
          <span class="text-xs shrink-0 mt-0.5">{event_icon(event.type)}</span>
          <span class={"text-sm font-medium shrink-0 #{agent_color(event.agent)}"}>
            {event.agent}
          </span>
          <span class="text-sm text-zinc-300 break-all">{event.content}</span>
        </div>
      </div>

      <%!-- Input bar --%>
      <div class="px-4 py-3 bg-zinc-900 border-t border-zinc-800">
        <form phx-submit="submit_command" class="flex gap-2">
          <input
            type="text"
            name="command"
            value={@command_input}
            placeholder="Create a task or run a command..."
            class="flex-1 bg-zinc-800 border border-zinc-700 rounded-lg px-4 py-2 text-sm text-zinc-100 placeholder-zinc-500 focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-transparent"
            autocomplete="off"
          />
          <button
            type="submit"
            class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium rounded-lg transition-colors"
          >
            Send
          </button>
        </form>
      </div>
    </div>

    """
  end

  # ── Helpers ──────────────────────────────────────────

  defp load_header_info do
    company_name =
      try do
        companies = DynamicSupervisor.which_children(Shazam.CompanySupervisor)

        case companies do
          [{_, pid, _, _} | _] when is_pid(pid) ->
            {:ok, info} = GenServer.call(pid, :info, 5_000)
            info.name

          _ ->
            "Shazam"
        end
      catch
        _, _ -> "Shazam"
      end

    status =
      try do
        if Shazam.RalphLoop.exists?(company_name) do
          case Shazam.RalphLoop.status(company_name) do
            %{paused: false} -> "running"
            %{paused: true} -> "paused"
            _ -> "idle"
          end
        else
          "idle"
        end
      catch
        _, _ -> "idle"
      end

    agent_count =
      try do
        Shazam.Company.get_agents(company_name) |> length()
      catch
        _, _ -> 0
      end

    {company_name, status, agent_count}
  end

  defp format_event_content(event) do
    type = get_field(event, :event) || get_in_safe(event, [:event]) || ""
    task = get_field(event, :task) || get_in_safe(event, [:task])
    task_title = if task, do: get_field(task, :title) || "", else: ""
    task_status = if task, do: get_field(task, :status) || "", else: ""

    cond do
      task_title != "" and task_status != "" ->
        "#{type}: #{task_title} (#{task_status})"

      task_title != "" ->
        "#{type}: #{task_title}"

      true ->
        type
    end
  end

  defp get_in_safe(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => val} -> {:cont, val}
        _ ->
          # Also try string keys when atom keys don't match
          str_key = to_string(key)
          case acc do
            %{^str_key => val} -> {:cont, val}
            _ -> {:halt, nil}
          end
      end
    end)
  end

  defp get_in_safe(_, _), do: nil

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_field(_, _), do: nil

  defp detect_company_and_pm do
    company_name =
      try do
        case DynamicSupervisor.which_children(Shazam.CompanySupervisor) do
          [{_, pid, _, _} | _] when is_pid(pid) ->
            {:ok, info} = GenServer.call(pid, :info, 5_000)
            info.name

          _ ->
            "Shazam"
        end
      catch
        _, _ -> "Shazam"
      end

    pm_name =
      try do
        agents = Shazam.Company.get_agents(company_name)

        case Enum.find(agents, fn agent ->
               role = agent |> agent_field(:role, "") |> to_string() |> String.downcase()
               String.contains?(role, "manager") or String.contains?(role, "pm")
             end) do
          nil ->
            case agents do
              [first | _] -> to_string(agent_field(first, :name, "pm"))
              _ -> "pm"
            end

          agent ->
            to_string(agent_field(agent, :name, "pm"))
        end
      catch
        _, _ -> "pm"
      end

    {company_name, pm_name}
  end

  defp agent_field(agent, key, default) do
    if is_struct(agent), do: Map.get(agent, key, default), else: agent[key] || default
  end

  defp event_icon("task_created"), do: "+"
  defp event_icon("task_completed"), do: "✓"
  defp event_icon("task_failed"), do: "✗"
  defp event_icon("task_checkout"), do: "→"
  defp event_icon("task_paused"), do: "‖"
  defp event_icon("task_resumed"), do: "▶"
  defp event_icon("task_approved"), do: "✓"
  defp event_icon("task_rejected"), do: "✗"
  defp event_icon("task_retried"), do: "↻"
  defp event_icon("task_deleted"), do: "×"
  defp event_icon(_), do: "•"

  defp agent_color(name) when is_binary(name) do
    hash = :erlang.phash2(name, 6)

    case hash do
      0 -> "text-emerald-400"
      1 -> "text-sky-400"
      2 -> "text-amber-400"
      3 -> "text-violet-400"
      4 -> "text-rose-400"
      _ -> "text-teal-400"
    end
  end

  defp agent_color(_), do: "text-zinc-400"

  defp status_color("running"), do: "bg-emerald-900/50 text-emerald-300"
  defp status_color("paused"), do: "bg-amber-900/50 text-amber-300"
  defp status_color(_), do: "bg-zinc-800 text-zinc-400"

  defp status_dot("running"), do: "bg-emerald-400 animate-pulse"
  defp status_dot("paused"), do: "bg-amber-400"
  defp status_dot(_), do: "bg-zinc-500"
end

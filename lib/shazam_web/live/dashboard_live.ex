defmodule ShazamWeb.DashboardLive do
  use ShazamWeb, :live_view

  @tick_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      try do
        Shazam.API.EventBus.subscribe()
      catch
        _, _ -> :ok
      end

      Process.send_after(self(), :tick, @tick_interval)
    end

    data = load_dashboard_data()

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       stats: data.stats,
       agents: data.agents,
       recent_events: data.recent_events,
       budget_overview: data.budget_overview
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval)
    data = load_dashboard_data()

    {:noreply,
     assign(socket,
       stats: data.stats,
       agents: data.agents,
       recent_events: data.recent_events,
       budget_overview: data.budget_overview
     )}
  end

  def handle_info({:event, _event}, socket) do
    data = load_dashboard_data()

    {:noreply,
     assign(socket,
       stats: data.stats,
       agents: data.agents,
       recent_events: data.recent_events,
       budget_overview: data.budget_overview
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold text-zinc-100">Dashboard</h1>

      <%!-- Stat Cards --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <p class="text-xs text-zinc-500 uppercase tracking-wider">Total Tasks</p>
          <p class="text-3xl font-bold text-zinc-100 mt-2">{@stats.total_tasks}</p>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <p class="text-xs text-zinc-500 uppercase tracking-wider">Running</p>
          <p class="text-3xl font-bold text-sky-400 mt-2">{@stats.running}</p>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <p class="text-xs text-zinc-500 uppercase tracking-wider">Tokens Used</p>
          <p class="text-3xl font-bold text-amber-400 mt-2">{format_number(@stats.tokens_used)}</p>
        </div>
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <p class="text-xs text-zinc-500 uppercase tracking-wider">Total Cost</p>
          <p class="text-3xl font-bold text-emerald-400 mt-2">{format_cost(@stats.total_cost)}</p>
        </div>
      </div>

      <%!-- Agent Performance Table --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl overflow-hidden">
        <div class="px-5 py-4 border-b border-zinc-800">
          <h2 class="text-lg font-semibold text-zinc-100">Agent Performance</h2>
        </div>
        <table class="w-full">
          <thead>
            <tr class="border-b border-zinc-800">
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Name</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Role</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Status</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">Completed</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">Failed</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">Tokens</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">Cost</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Activity</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={agent <- @agents}
              class="border-b border-zinc-800/50 hover:bg-zinc-800/30 transition-colors"
            >
              <td class="px-4 py-3 text-sm font-medium text-zinc-200">{agent.name}</td>
              <td class="px-4 py-3 text-sm text-zinc-400">{agent.role || "-"}</td>
              <td class="px-4 py-3">
                <span class={"inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium #{status_badge(agent.status)}"}>
                  {String.capitalize(to_string(agent.status))}
                </span>
              </td>
              <td class="px-4 py-3 text-sm text-emerald-400 text-right">{agent.tasks_completed}</td>
              <td class="px-4 py-3 text-sm text-red-400 text-right">{agent.tasks_failed}</td>
              <td class="px-4 py-3 text-sm text-zinc-300 text-right">{format_number(agent.tokens_used)}</td>
              <td class="px-4 py-3 text-sm text-zinc-300 text-right">{format_cost(agent.cost)}</td>
              <td class="px-4 py-3">
                <span class="font-mono text-emerald-400 text-xs">{agent.sparkline}</span>
              </td>
            </tr>
            <tr :if={@agents == []}>
              <td colspan="8" class="px-4 py-8 text-center text-sm text-zinc-500">
                No agents running.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Recent Activity --%>
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <h2 class="text-lg font-semibold text-zinc-100 mb-4">Recent Activity</h2>
          <div class="space-y-2">
            <div
              :for={event <- @recent_events}
              class="flex items-start gap-3 px-3 py-2 rounded-lg bg-zinc-800/30"
            >
              <span class="text-xs text-zinc-600 font-mono shrink-0 mt-0.5">
                {format_time(event.timestamp)}
              </span>
              <span class="text-sm text-zinc-300">{event.description}</span>
            </div>
            <p :if={@recent_events == []} class="text-sm text-zinc-500 text-center py-4">
              No recent activity.
            </p>
          </div>
        </div>

        <%!-- Budget Overview --%>
        <div class="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
          <h2 class="text-lg font-semibold text-zinc-100 mb-4">Budget Usage</h2>
          <div class="space-y-4">
            <div :for={entry <- @budget_overview}>
              <div class="flex items-center justify-between text-sm mb-1">
                <span class="text-zinc-300">{entry.name}</span>
                <span class="text-zinc-500">
                  {format_number(entry.used)} / {format_number(entry.budget)}
                </span>
              </div>
              <div class="w-full bg-zinc-800 rounded-full h-2">
                <div
                  class={"h-2 rounded-full #{budget_bar_color(entry.used, entry.budget)}"}
                  style={"width: #{budget_pct(entry.used, entry.budget)}%"}
                >
                </div>
              </div>
            </div>
            <p :if={@budget_overview == []} class="text-sm text-zinc-500 text-center py-4">
              No budget data available.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Data Loading ─────────────────────────────────────

  defp load_dashboard_data do
    tasks = try_call(fn -> Shazam.TaskBoard.list() end, [])
    all_metrics = try_call(fn -> Shazam.Metrics.get_all() end, %{})
    sparklines = try_call(fn -> Shazam.AgentPulse.all_sparklines() end, %{})
    company_name = detect_company()

    raw_agents =
      try do
        Shazam.Company.get_agents(company_name)
      catch
        _, _ -> []
      end

    # Stats
    total_tasks = length(tasks)

    running =
      Enum.count(tasks, fn t -> t.status in [:in_progress, :running] end)

    total_tokens =
      all_metrics
      |> Enum.reduce(0, fn {_name, m}, acc -> acc + Map.get(m, :tokens_used, 0) end)

    total_cost = total_tokens * 0.003 / 1000

    stats = %{
      total_tasks: total_tasks,
      running: running,
      tokens_used: total_tokens,
      total_cost: total_cost
    }

    # Agent performance
    agents =
      Enum.map(raw_agents, fn agent ->
        name = to_string(af(agent, :name, "unknown"))
        metrics = Map.get(all_metrics, name, %{})
        tokens = Map.get(metrics, :tokens_used, 0)

        %{
          name: name,
          role: af(agent, :role, ""),
          status: Map.get(metrics, :status, "idle"),
          tasks_completed: Map.get(metrics, :tasks_completed, 0),
          tasks_failed: Map.get(metrics, :tasks_failed, 0),
          tokens_used: tokens,
          cost: tokens * 0.003 / 1000,
          sparkline: Map.get(sparklines, name, ""),
          budget: af(agent, :budget, 100_000)
        }
      end)

    # Recent events (last 10 tasks by updated_at)
    recent_events =
      tasks
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(10)
      |> Enum.map(fn t ->
        %{
          timestamp: t.updated_at,
          description: "#{t.title} - #{format_status(t.status)}#{if t.assigned_to, do: " (#{t.assigned_to})", else: ""}"
        }
      end)

    # Budget overview
    budget_overview =
      Enum.map(agents, fn a ->
        %{name: a.name, used: a.tokens_used, budget: a.budget}
      end)

    %{
      stats: stats,
      agents: agents,
      recent_events: recent_events,
      budget_overview: budget_overview
    }
  end

  # Access struct or map fields safely
  defp af(agent, key, default) do
    if is_struct(agent), do: Map.get(agent, key, default), else: agent[key] || default
  end

  defp detect_company do
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
  end

  defp try_call(fun, default) do
    try do
      fun.()
    catch
      _, _ -> default
    end
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: Float.round(n, 1) |> to_string()
  defp format_number(_), do: "0"

  defp format_cost(cost) when is_float(cost) and cost >= 1.0,
    do: "$#{Float.round(cost, 2)}"

  defp format_cost(cost) when is_float(cost),
    do: "$#{Float.round(cost, 4)}"

  defp format_cost(_), do: "$0.00"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp format_status(:in_progress), do: "running"
  defp format_status(:awaiting_approval), do: "awaiting"
  defp format_status(s) when is_atom(s), do: Atom.to_string(s)
  defp format_status(s), do: to_string(s)

  defp status_badge("working"), do: "bg-emerald-900/50 text-emerald-300"
  defp status_badge("thinking"), do: "bg-sky-900/50 text-sky-300"
  defp status_badge(_), do: "bg-zinc-800 text-zinc-400"

  defp budget_pct(used, budget) when is_integer(budget) and budget > 0,
    do: min(100, round(used / budget * 100))

  defp budget_pct(_, _), do: 0

  defp budget_bar_color(used, budget) when is_integer(budget) and budget > 0 do
    pct = used / budget * 100

    cond do
      pct > 90 -> "bg-red-500"
      pct > 70 -> "bg-amber-500"
      true -> "bg-emerald-500"
    end
  end

  defp budget_bar_color(_, _), do: "bg-emerald-500"
end

defmodule ShazamWeb.AgentsLive do
  use ShazamWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      try do
        Shazam.API.EventBus.subscribe()
      catch
        _, _ -> :ok
      end
    end

    {agents, org_chart} = load_agents_data()

    {:ok,
     assign(socket,
       page_title: "Agents",
       agents: agents,
       org_chart: org_chart
     )}
  end

  @impl true
  def handle_info({:event, _event}, socket) do
    {agents, org_chart} = load_agents_data()
    {:noreply, assign(socket, agents: agents, org_chart: org_chart)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <h1 class="text-2xl font-bold text-zinc-100">Agents</h1>

      <%!-- Agent Cards Grid --%>
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        <div
          :for={agent <- @agents}
          class="bg-zinc-900 border border-zinc-800 rounded-xl p-5 hover:border-zinc-700 transition-colors"
        >
          <%!-- Header --%>
          <div class="flex items-start justify-between mb-3">
            <div>
              <h3 class="text-base font-semibold text-zinc-100">{agent.name}</h3>
              <p class="text-xs text-zinc-500">{agent.role || "No role"}</p>
            </div>
            <span class={"inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium #{agent_status_badge(agent.status)}"}>
              <span class={"w-1.5 h-1.5 rounded-full #{agent_status_dot(agent.status)}"}></span>
              {String.capitalize(to_string(agent.status))}
            </span>
          </div>

          <%!-- Domain --%>
          <div :if={agent.domain} class="mb-3">
            <span class="text-xs text-zinc-500">Domain:</span>
            <span class="text-xs text-zinc-300 ml-1">{agent.domain}</span>
          </div>

          <%!-- Sparkline --%>
          <div class="mb-3">
            <span class="text-xs text-zinc-500">Activity: </span>
            <span class="font-mono text-emerald-400 text-xs">{agent.sparkline}</span>
          </div>

          <%!-- Token Usage Bar --%>
          <div class="mb-3">
            <div class="flex items-center justify-between text-xs mb-1">
              <span class="text-zinc-500">Tokens</span>
              <span class="text-zinc-400">
                {format_number(agent.tokens_used)} / {format_number(agent.budget)}
              </span>
            </div>
            <div class="w-full bg-zinc-800 rounded-full h-1.5">
              <div
                class={"h-1.5 rounded-full #{token_bar_color(agent.tokens_used, agent.budget)}"}
                style={"width: #{token_pct(agent.tokens_used, agent.budget)}%"}
              >
              </div>
            </div>
          </div>

          <%!-- Current Task --%>
          <div :if={agent.current_task} class="mb-3">
            <span class="text-xs text-zinc-500">Working on:</span>
            <p class="text-sm text-emerald-300 mt-0.5 truncate">{agent.current_task}</p>
          </div>

          <%!-- Cost --%>
          <div class="flex items-center justify-between text-xs">
            <span class="text-zinc-500">Cost</span>
            <span class="text-zinc-300">{format_cost(agent.cost)}</span>
          </div>

          <%!-- Stats --%>
          <div class="flex items-center gap-4 mt-3 pt-3 border-t border-zinc-800">
            <div class="text-xs">
              <span class="text-emerald-400">{agent.tasks_completed}</span>
              <span class="text-zinc-600 ml-0.5">done</span>
            </div>
            <div class="text-xs">
              <span class="text-red-400">{agent.tasks_failed}</span>
              <span class="text-zinc-600 ml-0.5">failed</span>
            </div>
          </div>
        </div>
      </div>

      <div :if={@agents == []} class="bg-zinc-900 border border-zinc-800 rounded-xl p-8 text-center">
        <p class="text-zinc-500">No agents configured. Start a company to see agents here.</p>
      </div>

      <%!-- Org Chart --%>
      <div :if={@org_chart != ""} class="bg-zinc-900 border border-zinc-800 rounded-xl p-6">
        <h2 class="text-lg font-semibold text-zinc-100 mb-4">Organization Chart</h2>
        <pre class="font-mono text-sm text-zinc-300 whitespace-pre-wrap">{@org_chart}</pre>
      </div>
      <div :if={@org_chart == ""} class="bg-zinc-900 border border-zinc-800 rounded-xl p-6">
        <p class="text-zinc-500 text-sm">Start a company to see the org chart.</p>
      </div>
    </div>
    """
  end

  # ── Data Loading ─────────────────────────────────────

  defp load_agents_data do
    company_name = detect_company()

    agents =
      try do
        raw_agents = Shazam.Company.get_agents(company_name)
        sparklines = try_call(fn -> Shazam.AgentPulse.all_sparklines() end, %{})

        Enum.map(raw_agents, fn agent ->
          name = to_string(agent_field(agent, :name, "unknown"))
          metrics = try_call(fn -> Shazam.Metrics.get_agent(name) end, nil) || %{}
          sparkline = Map.get(sparklines, name, "")

          tasks =
            try do
              Shazam.TaskBoard.list(%{assigned_to: name, status: :in_progress})
            catch
              _, _ -> []
            end

          current_task =
            case tasks do
              [t | _] -> t.title
              _ -> nil
            end

          budget = agent_field(agent, :budget, 100_000)
          tokens_used = Map.get(metrics, :tokens_used, 0)
          cost = tokens_used * 0.003 / 1000

          %{
            name: name,
            role: agent_field(agent, :role, ""),
            domain: agent_field(agent, :domain, nil),
            supervisor: agent_field(agent, :supervisor, nil),
            status: Map.get(metrics, :status, "idle"),
            sparkline: sparkline,
            tokens_used: tokens_used,
            budget: budget,
            current_task: current_task,
            cost: cost,
            tasks_completed: Map.get(metrics, :tasks_completed, 0),
            tasks_failed: Map.get(metrics, :tasks_failed, 0)
          }
        end)
      catch
        _, _ -> []
      end

    org_chart =
      try do
        case Shazam.Company.org_chart(company_name) do
          chart when is_binary(chart) -> chart
          chart when is_list(chart) -> format_org_tree(chart, 0)
          _ -> ""
        end
      catch
        _, _ -> ""
      end

    {agents, org_chart || ""}
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

  defp format_org_tree(nodes, depth) when is_list(nodes) do
    Enum.map_join(nodes, "", fn node ->
      indent = String.duplicate("  ", depth)
      name = node[:name] || node["name"] || "?"
      role = node[:role] || node["role"] || ""
      subs = node[:subordinates] || node["subordinates"] || []
      line = "#{indent}#{if depth > 0, do: "└─ ", else: ""}#{name} (#{role})\n"
      line <> format_org_tree(subs, depth + 1)
    end)
  end
  defp format_org_tree(_, _), do: ""

  # Access struct or map fields safely (AgentWorker doesn't implement Access)
  defp agent_field(agent, key, default) do
    if is_struct(agent), do: Map.get(agent, key, default), else: agent[key] || default
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

  defp token_pct(used, budget) when is_integer(budget) and budget > 0,
    do: min(100, round(used / budget * 100))

  defp token_pct(_, _), do: 0

  defp token_bar_color(used, budget) when is_integer(budget) and budget > 0 do
    pct = used / budget * 100

    cond do
      pct > 90 -> "bg-red-500"
      pct > 70 -> "bg-amber-500"
      true -> "bg-emerald-500"
    end
  end

  defp token_bar_color(_, _), do: "bg-emerald-500"

  defp agent_status_badge("working"), do: "bg-emerald-900/50 text-emerald-300"
  defp agent_status_badge("thinking"), do: "bg-sky-900/50 text-sky-300"
  defp agent_status_badge(_), do: "bg-zinc-800 text-zinc-400"

  defp agent_status_dot("working"), do: "bg-emerald-400 animate-pulse"
  defp agent_status_dot("thinking"), do: "bg-sky-400 animate-pulse"
  defp agent_status_dot(_), do: "bg-zinc-500"
end

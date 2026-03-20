defmodule ShazamWeb.TasksLive do
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

    tasks = load_tasks()

    {:ok,
     assign(socket,
       page_title: "Tasks",
       tasks: tasks,
       filter: "all",
       show_form: false,
       form_title: "",
       form_description: "",
       form_assigned_to: ""
     )}
  end

  @impl true
  def handle_info({:event, _event}, socket) do
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form)}
  end

  def handle_event("create_task", params, socket) do
    {company_name, pm_name} = detect_company_and_pm()

    assigned = blank_to_nil(params["assigned_to"]) || pm_name

    attrs = %{
      title: params["title"] || "Untitled",
      description: params["description"],
      assigned_to: assigned,
      created_by: "web_ui",
      company: company_name
    }

    try do
      Shazam.TaskBoard.create(attrs)
    catch
      _, _ -> :ok
    end

    {:noreply, assign(socket, show_form: false, tasks: load_tasks())}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.approve(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.reject(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  def handle_event("pause", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.pause(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.resume_task(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.retry(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    try_action(fn -> Shazam.TaskBoard.delete(id) end)
    {:noreply, assign(socket, tasks: load_tasks())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-zinc-100">Tasks</h1>
        <button
          phx-click="toggle_form"
          class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium rounded-lg transition-colors"
        >
          {if @show_form, do: "Cancel", else: "New Task"}
        </button>
      </div>

      <%!-- New Task Form --%>
      <div :if={@show_form} class="bg-zinc-900 border border-zinc-800 rounded-xl p-6">
        <h3 class="text-lg font-semibold text-zinc-100 mb-4">Create New Task</h3>
        <form phx-submit="create_task" class="space-y-4">
          <div>
            <label class="block text-sm text-zinc-400 mb-1">Title</label>
            <input
              type="text"
              name="title"
              required
              class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-4 py-2 text-sm text-zinc-100 placeholder-zinc-500 focus:outline-none focus:ring-2 focus:ring-emerald-500"
              placeholder="Task title"
            />
          </div>
          <div>
            <label class="block text-sm text-zinc-400 mb-1">Description</label>
            <textarea
              name="description"
              rows="3"
              class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-4 py-2 text-sm text-zinc-100 placeholder-zinc-500 focus:outline-none focus:ring-2 focus:ring-emerald-500"
              placeholder="Optional description"
            ></textarea>
          </div>
          <div>
            <label class="block text-sm text-zinc-400 mb-1">Assign To</label>
            <input
              type="text"
              name="assigned_to"
              class="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-4 py-2 text-sm text-zinc-100 placeholder-zinc-500 focus:outline-none focus:ring-2 focus:ring-emerald-500"
              placeholder="Agent name (optional)"
            />
          </div>
          <button
            type="submit"
            class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium rounded-lg transition-colors"
          >
            Create Task
          </button>
        </form>
      </div>

      <%!-- Filter Tabs --%>
      <div class="flex gap-1 bg-zinc-900 rounded-xl p-1">
        <button
          :for={f <- [{"all", "All"}, {"pending", "Pending"}, {"running", "Running"}, {"completed", "Completed"}, {"failed", "Failed"}, {"awaiting", "Awaiting"}]}
          phx-click="filter"
          phx-value-filter={elem(f, 0)}
          class={"px-4 py-2 text-sm rounded-lg transition-colors #{if @filter == elem(f, 0), do: "bg-zinc-800 text-emerald-400 font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-zinc-800/50"}"}
        >
          {elem(f, 1)}
          <span class="ml-1 text-xs text-zinc-600">({count_for_filter(elem(f, 0), @tasks)})</span>
        </button>
      </div>

      <%!-- Task Table --%>
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl overflow-hidden">
        <table class="w-full">
          <thead>
            <tr class="border-b border-zinc-800">
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">ID</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Title</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Status</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Agent</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Created</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={task <- filtered_tasks(@tasks, @filter)}
              class="border-b border-zinc-800/50 hover:bg-zinc-800/30 transition-colors"
            >
              <td class="px-4 py-3 text-xs font-mono text-zinc-500">{task.id}</td>
              <td class="px-4 py-3 text-sm text-zinc-200">{task.title}</td>
              <td class="px-4 py-3">
                <span class={"inline-flex px-2.5 py-0.5 rounded-full text-xs font-medium #{status_badge(task.status)}"}>
                  {format_status(task.status)}
                </span>
              </td>
              <td class="px-4 py-3 text-sm text-zinc-400">{task.assigned_to || "-"}</td>
              <td class="px-4 py-3 text-xs text-zinc-500">{format_datetime(task.created_at)}</td>
              <td class="px-4 py-3 text-right">
                <div class="flex items-center justify-end gap-1">
                  <button
                    :if={task.status == :awaiting_approval}
                    phx-click="approve"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-emerald-900/50 text-emerald-300 rounded hover:bg-emerald-800/50 transition-colors"
                  >
                    Approve
                  </button>
                  <button
                    :if={task.status == :awaiting_approval}
                    phx-click="reject"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-red-900/50 text-red-300 rounded hover:bg-red-800/50 transition-colors"
                  >
                    Reject
                  </button>
                  <button
                    :if={task.status in [:pending, :in_progress]}
                    phx-click="pause"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-amber-900/50 text-amber-300 rounded hover:bg-amber-800/50 transition-colors"
                  >
                    Pause
                  </button>
                  <button
                    :if={task.status == :paused}
                    phx-click="resume"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-sky-900/50 text-sky-300 rounded hover:bg-sky-800/50 transition-colors"
                  >
                    Resume
                  </button>
                  <button
                    :if={task.status in [:failed, :completed, :rejected]}
                    phx-click="retry"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-violet-900/50 text-violet-300 rounded hover:bg-violet-800/50 transition-colors"
                  >
                    Retry
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={task.id}
                    class="px-2 py-1 text-xs bg-zinc-800 text-zinc-400 rounded hover:bg-red-900/50 hover:text-red-300 transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={filtered_tasks(@tasks, @filter) == []}>
              <td colspan="6" class="px-4 py-8 text-center text-sm text-zinc-500">
                No tasks found.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────

  defp load_tasks do
    try do
      Shazam.TaskBoard.list()
    catch
      _, _ -> []
    end
  end

  defp try_action(fun) do
    try do
      fun.()
    catch
      _, _ -> :ok
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: s

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

  defp filtered_tasks(tasks, "all"), do: tasks
  defp filtered_tasks(tasks, "pending"), do: Enum.filter(tasks, &(&1.status == :pending))

  defp filtered_tasks(tasks, "running"),
    do: Enum.filter(tasks, &(&1.status in [:in_progress, :running]))

  defp filtered_tasks(tasks, "completed"), do: Enum.filter(tasks, &(&1.status == :completed))
  defp filtered_tasks(tasks, "failed"), do: Enum.filter(tasks, &(&1.status == :failed))

  defp filtered_tasks(tasks, "awaiting"),
    do: Enum.filter(tasks, &(&1.status == :awaiting_approval))

  defp filtered_tasks(tasks, _), do: tasks

  defp count_for_filter(filter, tasks), do: length(filtered_tasks(tasks, filter))

  defp status_badge(:pending), do: "bg-amber-900/50 text-amber-300"
  defp status_badge(:in_progress), do: "bg-sky-900/50 text-sky-300"
  defp status_badge(:running), do: "bg-sky-900/50 text-sky-300"
  defp status_badge(:completed), do: "bg-emerald-900/50 text-emerald-300"
  defp status_badge(:failed), do: "bg-red-900/50 text-red-300"
  defp status_badge(:awaiting_approval), do: "bg-violet-900/50 text-violet-300"
  defp status_badge(:paused), do: "bg-amber-900/50 text-amber-300"
  defp status_badge(:rejected), do: "bg-red-900/50 text-red-300"
  defp status_badge(_), do: "bg-zinc-800 text-zinc-400"

  defp format_status(:awaiting_approval), do: "Awaiting"
  defp format_status(:in_progress), do: "Running"
  defp format_status(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  defp format_status(status), do: to_string(status)

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "-"
end

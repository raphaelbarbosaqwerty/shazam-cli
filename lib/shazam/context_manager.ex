defmodule Shazam.ContextManager do
  @moduledoc """
  Cross-provider context persistence with atomized skill-graph storage.

  Instead of one giant file per agent, context is split into small topic files
  with an index that references them. This gives TF-IDF better chunks and
  keeps token injection minimal.

  ## Storage

      .shazam/context/
        agents/
          senior_1/
            index.md           # 20 lines — links to topic files
            auth.md            # JWT, middleware, tokens
            database.md        # migrations, schema
            api.md             # endpoints created
          pm/
            index.md
            planning.md
            delegation.md
        team_activity.md       # chronological log (auto-trimmed)

  ## Configuration (shazam.yaml)

      config:
        context_history: 5
        team_activity: 10
        context_budget: 4000
  """

  use GenServer
  require Logger

  @default_history 5
  @default_team_activity 10
  @default_budget 4_000
  @max_team_entries 200
  @max_topic_lines 100
  @min_similarity 2

  # ── Public API ────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Capture a completed task's context. Fire-and-forget."
  def capture(agent_name, task, output, touched_files \\ []) do
    GenServer.cast(__MODULE__, {:capture, agent_name, task, output, touched_files})
  end

  @doc "Build context string for an agent's next task."
  def build_context(agent_name, task) do
    GenServer.call(__MODULE__, {:build_context, agent_name, task}, :timer.seconds(5))
  catch
    :exit, _ -> ""
  end

  @doc "Update configuration at runtime."
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  # ── Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, %{
      context_history: Keyword.get(opts, :context_history, @default_history),
      team_activity: Keyword.get(opts, :team_activity, @default_team_activity),
      context_budget: Keyword.get(opts, :context_budget, @default_budget)
    }}
  end

  @impl true
  def handle_cast({:capture, agent_name, task, output, touched_files}, state) do
    try do
      title = task[:title] || task.title || "untitled"
      output_str = to_string(output)
      summary = summarize(output_str)
      files_list = touched_files || []
      ts = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M")

      entry = "### [#{ts}] #{title}\n#{summary}#{format_files(files_list)}\n\n"

      # 1. Route to the right topic file (or create new)
      route_to_topic(agent_name, title, entry, files_list)

      # 2. Append to team activity
      team_entry = "### [#{ts}] #{agent_name}: #{title}#{format_files(files_list)}\n  #{String.slice(summary, 0..150)}\n\n"
      append_file(team_activity_path(), team_entry)
      trim_file(team_activity_path(), @max_team_entries)

      # 3. Extract learnings (decisions, discoveries, patterns)
      extract_learnings(agent_name, title, output_str, files_list, ts)

      # 4. Update agent index
      update_agent_index(agent_name)
    rescue
      e -> Logger.debug("[ContextManager] capture failed: #{inspect(e)}")
    end
    {:noreply, state}
  end

  @impl true
  def handle_call({:build_context, agent_name, task}, _from, state) do
    context = try do
      # Agent's recent work from their topic files
      agent_history = read_agent_recent(agent_name, state.context_history)

      # Agent's accumulated learnings
      learnings = read_learnings(agent_name)

      # Team activity
      team_history = read_last_entries(team_activity_path(), state.team_activity)

      # TF-IDF across all context files
      query = "#{task[:title] || task.title} #{task[:description] || ""}"
      rag_results = Shazam.ContextRAG.search_formatted(query,
        budget: div(state.context_budget, 4),
        top_k: 5
      )

      assemble(agent_history, learnings, team_history, rag_results, state.context_budget)
    rescue
      _ -> ""
    end
    {:reply, context, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    state = %{state |
      context_history: Keyword.get(opts, :context_history, state.context_history),
      team_activity: Keyword.get(opts, :team_activity, state.team_activity),
      context_budget: Keyword.get(opts, :context_budget, state.context_budget)
    }
    {:reply, :ok, state}
  end

  # ── Topic Routing ─────────────────────────────────────

  defp route_to_topic(agent_name, title, entry, files) do
    agent_dir = agent_dir(agent_name)
    if agent_dir == nil, do: throw(:no_workspace)

    File.mkdir_p!(agent_dir)

    # Find the best matching topic file, or create a new one
    topic = find_best_topic(agent_dir, title, files)
    topic_path = Path.join(agent_dir, "#{topic}.md")

    append_file(topic_path, entry)

    # Auto-split if topic file is too large
    maybe_split_topic(topic_path, agent_dir)
  end

  defp find_best_topic(agent_dir, title, files) do
    existing = list_topic_files(agent_dir)

    if existing == [] do
      slugify(title)
    else
      # Score each topic by keyword overlap with title + files
      title_tokens = tokenize(title <> " " <> Enum.join(files, " "))

      scored = Enum.map(existing, fn topic_name ->
        topic_path = Path.join(agent_dir, "#{topic_name}.md")
        topic_content = File.read!(topic_path) |> String.slice(0..500)
        topic_tokens = tokenize(topic_name <> " " <> topic_content)

        overlap = MapSet.intersection(
          MapSet.new(title_tokens),
          MapSet.new(topic_tokens)
        ) |> MapSet.size()

        {overlap, topic_name}
      end)

      {best_score, best_topic} = Enum.max_by(scored, fn {score, _} -> score end)

      if best_score >= @min_similarity do
        best_topic
      else
        slugify(title)
      end
    end
  end

  defp maybe_split_topic(path, _agent_dir) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        if length(lines) > @max_topic_lines do
          # Keep last 60% of entries, archive the rest naturally
          # (old entries remain but new searches favor recent via TF-IDF)
          entries = String.split(content, ~r/(?=^### \[)/m) |> Enum.reject(&(&1 == ""))
          keep = max(div(length(entries), 2), 3)
          trimmed = entries |> Enum.take(-keep) |> Enum.join("")
          File.write!(path, trimmed)
        end
      _ -> :ok
    end
  end

  defp list_topic_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == "index.md"))
        |> Enum.map(&String.trim_trailing(&1, ".md"))
      _ -> []
    end
  end

  # ── Index Management ──────────────────────────────────

  defp update_agent_index(agent_name) do
    dir = agent_dir(agent_name)
    if dir == nil, do: throw(:no_workspace)

    topics = list_topic_files(dir)
    if topics == [] do
      :ok
    else
      topic_lines = Enum.map(topics, fn topic ->
        path = Path.join(dir, "#{topic}.md")
        desc = case File.read(path) do
          {:ok, content} ->
            content
            |> String.split("\n")
            |> Enum.find("", &String.starts_with?(&1, "### "))
            |> String.replace(~r/^### \[.*?\]\s*/, "")
            |> String.slice(0..60)
          _ -> ""
        end
        "- [#{topic}.md](#{topic}.md) — #{desc}"
      end)

      # Include learnings summary
      learnings_section = case File.read(Path.join(dir, "_learnings.md")) do
        {:ok, content} ->
          recent = content
            |> String.split(~r/(?=^### \[)/m)
            |> Enum.reject(&(&1 == ""))
            |> Enum.take(-3)
            |> Enum.flat_map(fn block ->
              Regex.scan(~r/^- (.+)$/m, block) |> Enum.map(fn [_, l] -> l end)
            end)
            |> Enum.take(5)

          if recent != [] do
            "\n## Key Learnings\n" <> Enum.map_join(recent, "\n", &"- #{&1}")
          else
            ""
          end
        _ -> ""
      end

      index = "# #{agent_name} — Context Index\n\n## Topics\n#{Enum.join(topic_lines, "\n")}#{learnings_section}\n"
      File.write!(Path.join(dir, "index.md"), index)
    end
  end

  # ── Read Helpers ──────────────────────────────────────

  defp read_agent_recent(agent_name, n) do
    dir = agent_dir(agent_name)
    if dir == nil or not File.dir?(dir), do: "", else: do_read_agent_recent(dir, n)
  end

  defp do_read_agent_recent(dir, n) do
    # Collect entries from all topic files, sort by timestamp, take last N
    list_topic_files(dir)
    |> Enum.flat_map(fn topic ->
      path = Path.join(dir, "#{topic}.md")
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split(~r/(?=^### \[)/m)
          |> Enum.reject(&(&1 == ""))
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.take(-n)
    |> Enum.join("")
  end

  defp read_learnings(agent_name) do
    case learnings_path(agent_name) do
      nil -> ""
      path ->
        case File.read(path) do
          {:ok, content} ->
            # Get unique learnings (deduplicated)
            content
            |> then(&Regex.scan(~r/^- (.+)$/m, &1))
            |> Enum.map(fn [_, l] -> l end)
            |> Enum.uniq_by(&String.downcase/1)
            |> Enum.take(15)
            |> Enum.map_join("\n", &"- #{&1}")
          _ -> ""
        end
    end
  end

  defp read_last_entries(nil, _n), do: ""
  defp read_last_entries(path, n) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(~r/(?=^### \[)/m)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-n)
        |> Enum.join("")
      _ -> ""
    end
  end

  # ── Assembly ──────────────────────────────────────────

  defp assemble(agent_history, learnings, team_history, rag_results, budget) do
    sections = []
    sections = if learnings != "", do: sections ++ ["## What You Know\n#{learnings}"], else: sections
    sections = if agent_history != "", do: sections ++ ["## Your Recent Work\n#{agent_history}"], else: sections
    sections = if team_history != "", do: sections ++ ["## Recent Team Activity\n#{team_history}"], else: sections
    sections = if rag_results != "", do: sections ++ ["## Related Context\n#{rag_results}"], else: sections

    if sections == [] do
      ""
    else
      result = Enum.join(sections, "\n")
      if String.length(result) > budget do
        String.slice(result, 0, budget) <> "\n[...context truncated]"
      else
        result
      end
    end
  end

  # ── Learnings Extraction ───────────────────────────────

  @learning_patterns [
    # Decisions
    ~r/(?:chose|decided|using|picked|selected|went with|prefer|switched to)\s+(.{10,120})/i,
    # Discoveries
    ~r/(?:found that|discovered|noticed|turns out|realized|project uses|built with|powered by)\s+(.{10,120})/i,
    # Patterns
    ~r/(?:pattern|convention|approach|architecture|structure|stack)(?:\s+is|\s*:)\s+(.{10,120})/i,
    # Dependencies
    ~r/(?:depends on|requires|uses|imports?|installed?)\s+([\w@\/-]+(?:\s+[\w@\/-]+){0,5})/i,
    # Warnings/gotchas
    ~r/(?:careful|warning|note|important|gotcha|caveat|don't|avoid|never)\s*:?\s+(.{10,120})/i,
  ]

  defp extract_learnings(agent_name, title, output, files, ts) do
    learnings = extract_patterns(output)

    # Also extract tech stack / dependency info from file paths
    file_learnings = extract_file_learnings(files)

    all_learnings = (learnings ++ file_learnings) |> Enum.uniq()

    if all_learnings != [] do
      path = learnings_path(agent_name)
      existing = read_existing_learnings(path)

      # Deduplicate — don't add learnings we already know
      new_learnings = Enum.reject(all_learnings, fn learning ->
        normalized = String.downcase(learning) |> String.trim()
        Enum.any?(existing, fn existing_l ->
          similarity(normalized, String.downcase(existing_l)) > 0.7
        end)
      end)

      if new_learnings != [] do
        entries = Enum.map(new_learnings, fn l -> "- #{l}" end) |> Enum.join("\n")
        entry = "### [#{ts}] From: #{title}\n#{entries}\n\n"
        append_file(path, entry)
        trim_file(path, 100)
      end
    end
  end

  defp extract_patterns(output) do
    @learning_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, output)
      |> Enum.map(fn
        [_full, capture] -> String.trim(capture) |> String.replace(~r/\s+/, " ")
        [full] -> String.trim(full) |> String.slice(0..120)
      end)
    end)
    |> Enum.reject(&(String.length(&1) < 10))
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp extract_file_learnings(files) do
    files
    |> Enum.flat_map(fn path ->
      cond do
        String.contains?(path, "package.json") -> ["Project uses Node.js/npm"]
        String.contains?(path, "mix.exs") -> ["Project uses Elixir/Mix"]
        String.contains?(path, "Cargo.toml") -> ["Project uses Rust/Cargo"]
        String.contains?(path, "pubspec.yaml") -> ["Project uses Dart/Flutter"]
        String.contains?(path, "go.mod") -> ["Project uses Go modules"]
        String.contains?(path, "requirements.txt") or String.contains?(path, "pyproject.toml") -> ["Project uses Python"]
        String.contains?(path, "Gemfile") -> ["Project uses Ruby/Bundler"]
        String.contains?(path, "supabase") -> ["Project uses Supabase"]
        String.contains?(path, "prisma") -> ["Project uses Prisma ORM"]
        String.contains?(path, ".vue") -> ["Project uses Vue.js"]
        String.contains?(path, ".tsx") or String.contains?(path, ".jsx") -> ["Project uses React"]
        String.contains?(path, ".svelte") -> ["Project uses Svelte"]
        true -> []
      end
    end)
    |> Enum.uniq()
  end

  defp read_existing_learnings(path) do
    case File.read(path) do
      {:ok, content} ->
        Regex.scan(~r/^- (.+)$/m, content)
        |> Enum.map(fn [_, l] -> String.trim(l) end)
      _ -> []
    end
  end

  defp similarity(a, b) do
    tokens_a = MapSet.new(String.split(a))
    tokens_b = MapSet.new(String.split(b))
    intersection = MapSet.intersection(tokens_a, tokens_b) |> MapSet.size()
    union = MapSet.union(tokens_a, tokens_b) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end

  defp learnings_path(agent_name) do
    case agent_dir(agent_name) do
      nil -> nil
      dir -> Path.join(dir, "_learnings.md")
    end
  end

  # ── Utilities ─────────────────────────────────────────

  defp summarize(output) do
    output
    |> to_string()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(4)
    |> Enum.join("\n")
    |> String.slice(0..300)
  end

  defp format_files([]), do: ""
  defp format_files(files), do: "\nFiles: #{Enum.join(files, ", ")}"

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
    |> Enum.join("_")
    |> then(fn s -> if s == "", do: "general", else: s end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, " ")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp append_file(nil, _), do: :ok
  defp append_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:append])
  end

  defp trim_file(nil, _max), do: :ok
  defp trim_file(path, max) do
    case File.read(path) do
      {:ok, content} ->
        entries = String.split(content, ~r/(?=^### \[)/m) |> Enum.reject(&(&1 == ""))
        if length(entries) > max do
          File.write!(path, entries |> Enum.take(-max) |> Enum.join(""))
        end
      _ -> :ok
    end
  end

  # ── Paths ─────────────────────────────────────────────

  defp context_dir do
    case Application.get_env(:shazam, :workspace) do
      nil -> nil
      ws -> Path.join([ws, ".shazam", "context"])
    end
  end

  defp agent_dir(agent_name) do
    case context_dir() do
      nil -> nil
      dir -> Path.join([dir, "agents", to_string(agent_name)])
    end
  end

  defp team_activity_path do
    case context_dir() do
      nil -> nil
      dir -> Path.join(dir, "team_activity.md")
    end
  end
end

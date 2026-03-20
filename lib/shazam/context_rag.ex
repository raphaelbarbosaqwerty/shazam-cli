defmodule Shazam.ContextRAG do
  @moduledoc """
  TF-IDF based retrieval for cross-provider context.

  Pure Elixir implementation — zero external dependencies.
  Indexes `.md` files from `.shazam/context/`, `.shazam/tasks/`,
  and `.shazam/memories/`, then retrieves the most relevant chunks
  for a given query using TF-IDF scoring.

  ## How it works

  1. **Tokenize** — split text into lowercase words, remove stopwords
  2. **TF (Term Frequency)** — how often a word appears in a document chunk
  3. **IDF (Inverse Document Frequency)** — how rare a word is across all chunks
  4. **Score** — TF * IDF for each query term, summed per chunk
  5. **Rank** — return top-K chunks by score

  ## Usage

      Shazam.ContextRAG.search("JWT authentication bug", top_k: 5)
      # => [
      #   {0.85, "### [2026-03-20] senior_1: Implement JWT auth\\n  Created /lib/jwt.ts..."},
      #   {0.72, "### [2026-03-20] pm: Delegated auth tasks\\n  ..."},
      # ]
  """

  @stopwords ~w(
    the a an and or but in on at to for of is it this that with from by as are was were
    been be have has had do does did will would shall should may might can could
    not no nor so if then else than too very just about above after before between
    each every all any both few more most other some such only same also how when where
    what which who whom whose why again further once here there these those their them
    they he she his her its our your we you my me him us
    task agent create created implement implemented build built add added fix fixed
    update updated use used make made
  )

  @doc "Search context files for the most relevant chunks to a query."
  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 5)
    max_chunk_chars = Keyword.get(opts, :max_chunk_chars, 500)

    chunks = load_all_chunks(max_chunk_chars)

    if chunks == [] do
      []
    else
      query_tokens = tokenize(query)

      if query_tokens == [] do
        []
      else
        idf = compute_idf(chunks)
        score_and_rank(chunks, query_tokens, idf, top_k)
      end
    end
  end

  @doc "Search and return formatted context string within a budget."
  def search_formatted(query, opts \\ []) do
    budget = Keyword.get(opts, :budget, 4_000)
    top_k = Keyword.get(opts, :top_k, 8)

    results = search(query, top_k: top_k)

    if results == [] do
      ""
    else
      results
      |> Enum.map(fn {_score, text} -> String.trim(text) end)
      |> Enum.reduce({"", 0}, fn chunk, {acc, len} ->
        new_len = len + String.length(chunk) + 2
        if new_len > budget do
          {acc, len}
        else
          {acc <> chunk <> "\n\n", new_len}
        end
      end)
      |> elem(0)
      |> String.trim()
    end
  end

  # ── Indexing ──────────────────────────────────────────

  defp load_all_chunks(max_chars) do
    workspace = Application.get_env(:shazam, :workspace)
    if workspace == nil, do: [], else: do_load_chunks(workspace, max_chars)
  end

  defp do_load_chunks(workspace, max_chars) do
    dirs = [
      Path.join([workspace, ".shazam", "context"]),
      Path.join([workspace, ".shazam", "tasks"]),
      Path.join([workspace, ".shazam", "memories"])
    ]

    dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      # Recursive search — finds files in subdirectories (agent topic files)
      Path.wildcard(Path.join(dir, "**/*.md"))
    end)
    |> Enum.reject(&String.ends_with?(&1, "index.md"))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> split_into_chunks(content, path, max_chars)
        _ -> []
      end
    end)
  end

  defp split_into_chunks(content, source_path, max_chars) do
    source = Path.basename(source_path, ".md")

    # Try splitting by ### headers first (context entries)
    entries = String.split(content, ~r/(?=^### )/m) |> Enum.reject(&(&1 == ""))

    if length(entries) > 1 do
      # Context/task files with ### headers
      Enum.map(entries, fn entry ->
        text = String.slice(entry, 0, max_chars)
        tokens = tokenize(text)
        %{text: text, tokens: tokens, source: source}
      end)
    else
      # Single document (memories, agent configs) — split by paragraphs
      content
      |> String.split(~r/\n\n+/)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.chunk_every(3) # group 3 paragraphs per chunk
      |> Enum.map(fn paragraphs ->
        text = Enum.join(paragraphs, "\n\n") |> String.slice(0, max_chars)
        tokens = tokenize(text)
        %{text: text, tokens: tokens, source: source}
      end)
    end
    |> Enum.reject(fn chunk -> chunk.tokens == [] end)
  end

  # ── TF-IDF ───────────────────────────────────────────

  defp compute_idf(chunks) do
    n = length(chunks)

    # Count how many chunks contain each token
    df = Enum.reduce(chunks, %{}, fn chunk, acc ->
      chunk.tokens
      |> Enum.uniq()
      |> Enum.reduce(acc, fn token, inner_acc ->
        Map.update(inner_acc, token, 1, &(&1 + 1))
      end)
    end)

    # IDF = log(N / df) + 1 (smoothed)
    Map.new(df, fn {token, count} ->
      {token, :math.log(n / count) + 1}
    end)
  end

  defp score_and_rank(chunks, query_tokens, idf, top_k) do
    chunks
    |> Enum.map(fn chunk ->
      score = compute_chunk_score(chunk, query_tokens, idf)
      {score, chunk.text}
    end)
    |> Enum.reject(fn {score, _} -> score == 0.0 end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.take(top_k)
  end

  defp compute_chunk_score(chunk, query_tokens, idf) do
    # Term frequency in this chunk
    tf = Enum.frequencies(chunk.tokens)
    max_tf = tf |> Map.values() |> Enum.max(fn -> 1 end)

    # Sum TF-IDF for each query token
    Enum.reduce(query_tokens, 0.0, fn qt, acc ->
      raw_tf = Map.get(tf, qt, 0)
      # Augmented TF to prevent bias toward long documents
      normalized_tf = if max_tf > 0, do: 0.5 + 0.5 * (raw_tf / max_tf), else: 0.0
      token_idf = Map.get(idf, qt, 1.0)

      if raw_tf > 0 do
        acc + normalized_tf * token_idf
      else
        # Partial match bonus — if query token is substring of a chunk token
        partial = Enum.any?(chunk.tokens, fn ct ->
          String.contains?(ct, qt) or String.contains?(qt, ct)
        end)
        if partial, do: acc + 0.3 * token_idf, else: acc
      end
    end)
  end

  # ── Tokenization ─────────────────────────────────────

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, " ")
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in @stopwords))
  end
end

defmodule Shazam.PRReviewer do
  @moduledoc "PR Review agent — reviews GitHub PRs using the full codebase context."

  require Logger

  @memories_dir ".shazam/memories/reviews"

  @doc "Check if gh CLI is available and authenticated."
  def check_gh do
    case System.find_executable("gh") do
      nil -> {:error, :not_installed}
      _path ->
        case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, :not_authenticated}
        end
    end
  end

  @doc "Review a PR by number or URL."
  def review(pr_ref, opts \\ []) do
    _opts = opts

    case check_gh() do
      {:error, :not_installed} ->
        {:error, "GitHub CLI (gh) not found. Install: brew install gh"}
      {:error, :not_authenticated} ->
        {:error, "GitHub CLI not authenticated. Run: gh auth login"}
      :ok ->
        do_review(pr_ref)
    end
  end

  defp do_review(pr_ref) do
    pr_number = extract_pr_number(pr_ref)
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    # Fetch PR data via gh CLI
    with {:ok, pr_info} <- fetch_pr_info(pr_number, workspace),
         {:ok, diff} <- fetch_pr_diff(pr_number, workspace),
         {:ok, files} <- fetch_changed_files(pr_number, workspace) do

      # Build review context
      patterns = load_review_patterns(workspace)
      file_contexts = read_full_files(files, workspace)

      {:ok, %{
        pr_number: pr_number,
        pr_info: pr_info,
        diff: diff,
        files: files,
        file_contexts: file_contexts,
        patterns: patterns
      }}
    end
  end

  @doc "Learn from merged PR reviews."
  def learn(opts \\ []) do
    case check_gh() do
      {:error, :not_installed} -> {:error, "GitHub CLI (gh) not found. Install: brew install gh"}
      {:error, :not_authenticated} -> {:error, "GitHub CLI not authenticated. Run: gh auth login"}
      :ok -> do_learn(opts)
    end
  end

  defp do_learn(opts) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    count = Keyword.get(opts, :count, 10)

    case System.cmd("gh", ["pr", "list", "--state", "merged", "--limit", "#{count}", "--json", "number,title"], cd: workspace, stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, prs} ->
            patterns = Enum.flat_map(prs, fn pr ->
              extract_review_patterns(pr["number"], workspace)
            end)
            save_patterns(patterns, workspace)
            {:ok, length(patterns)}
          _ -> {:error, :parse_failed}
        end
      {err, _} -> {:error, err}
    end
  end

  @doc "Get current learned patterns."
  def patterns do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    load_review_patterns(workspace)
  end

  @doc "Build a review prompt for the agent."
  def build_review_prompt(context) do
    patterns_section = if context.patterns != "" do
      "\n\n## Team Patterns (learned from past reviews)\n\n#{context.patterns}"
    else
      ""
    end

    files_section = context.file_contexts
    |> Enum.map(fn {file, content} ->
      "### #{file}\n```\n#{String.slice(content, 0..3000)}\n```"
    end)
    |> Enum.join("\n\n")

    """
    Review this pull request:

    ## PR ##{context.pr_number}
    #{context.pr_info}

    ## Diff
    ```diff
    #{String.slice(context.diff, 0..8000)}
    ```

    ## Full File Context (files that were changed)
    #{files_section}
    #{patterns_section}

    Please provide a thorough code review. For each issue:
    1. Specify the file and line
    2. Use severity: 🔴 bug, 🟡 issue, 🔵 suggestion, ✅ positive
    3. Explain the problem clearly
    4. Suggest a fix

    End with a verdict: APPROVE, REQUEST_CHANGES, or COMMENT.
    """
  end

  # ── Private ──────────────────────────────────────────────

  defp extract_pr_number(ref) when is_integer(ref), do: ref
  defp extract_pr_number(ref) when is_binary(ref) do
    cond do
      String.match?(ref, ~r/^\d+$/) -> String.to_integer(ref)
      String.contains?(ref, "/pull/") ->
        ref |> String.split("/pull/") |> List.last() |> String.split("/") |> List.first() |> String.to_integer()
      true -> String.to_integer(ref)
    end
  end

  defp fetch_pr_info(pr_number, workspace) do
    case System.cmd("gh", ["pr", "view", "#{pr_number}", "--json", "title,body,author,baseRefName,headRefName,additions,deletions,changedFiles"], cd: workspace, stderr_to_stdout: true) do
      {json, 0} -> {:ok, json}
      {err, _} -> {:error, "Failed to fetch PR info: #{err}"}
    end
  end

  defp fetch_pr_diff(pr_number, workspace) do
    case System.cmd("gh", ["pr", "diff", "#{pr_number}"], cd: workspace, stderr_to_stdout: true) do
      {diff, 0} -> {:ok, diff}
      {err, _} -> {:error, "Failed to fetch diff: #{err}"}
    end
  end

  defp fetch_changed_files(pr_number, workspace) do
    case System.cmd("gh", ["pr", "diff", "#{pr_number}", "--name-only"], cd: workspace, stderr_to_stdout: true) do
      {files, 0} -> {:ok, files |> String.split("\n") |> Enum.reject(&(&1 == ""))}
      {err, _} -> {:error, "Failed to fetch files: #{err}"}
    end
  end

  defp read_full_files(files, workspace) do
    files
    |> Enum.take(20)  # Limit to 20 files
    |> Enum.map(fn file ->
      path = Path.join(workspace, file)
      content = case File.read(path) do
        {:ok, c} -> c
        _ -> "[file not found]"
      end
      {file, content}
    end)
  end

  defp load_review_patterns(workspace) do
    path = Path.join([workspace, @memories_dir, "patterns.md"])
    case File.read(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp save_patterns(patterns, workspace) do
    dir = Path.join(workspace, @memories_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "patterns.md")

    existing = case File.read(path) do
      {:ok, content} -> content
      _ -> "# Review Patterns\n\nLearned from team PR reviews.\n"
    end

    new_content = existing <> "\n" <> Enum.join(patterns, "\n")
    File.write!(path, new_content)
  end

  defp extract_review_patterns(pr_number, workspace) do
    case System.cmd("gh", ["api", "repos/{owner}/{repo}/pulls/#{pr_number}/reviews", "--jq", ".[].body"], cd: workspace, stderr_to_stdout: true) do
      {reviews, 0} when reviews != "" ->
        reviews
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&("- #{String.slice(&1, 0..200)} (from PR ##{pr_number})"))
      _ -> []
    end
  end
end

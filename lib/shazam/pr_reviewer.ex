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

  @doc "Resolve all review threads on a PR (mark conversations as resolved)."
  def resolve_threads(pr_number) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    case check_gh() do
      {:error, _} = err -> err
      :ok ->
        try do
          # Get repo name
          {repo, 0} = System.cmd("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cd: workspace, stderr_to_stdout: true)
          repo = String.trim(repo)

          # Get all review threads via GraphQL
          query = """
          query {
            repository(owner: "#{String.split(repo, "/") |> List.first()}", name: "#{String.split(repo, "/") |> List.last()}") {
              pullRequest(number: #{pr_number}) {
                reviewThreads(first: 100) {
                  nodes {
                    id
                    isResolved
                  }
                }
              }
            }
          }
          """

          case System.cmd("gh", ["api", "graphql", "-f", "query=#{query}"], cd: workspace, stderr_to_stdout: true) do
            {result, 0} ->
              case Jason.decode(result) do
                {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => threads}}}}}} ->
                  unresolved = Enum.filter(threads, fn t -> !t["isResolved"] end)

                  Enum.each(unresolved, fn thread ->
                    mutation = """
                    mutation {
                      resolveReviewThread(input: {threadId: "#{thread["id"]}"}) {
                        thread { id }
                      }
                    }
                    """
                    System.cmd("gh", ["api", "graphql", "-f", "query=#{mutation}"], cd: workspace, stderr_to_stdout: true)
                  end)

                  {:ok, length(unresolved)}
                _ -> {:error, "Failed to parse threads"}
              end
            {err, _} -> {:error, err}
          end
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
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

    IMPORTANT: End your review with a JSON block in this exact format:

    ```json
    {
      "summary": "Brief overall assessment",
      "verdict": "APPROVE" or "REQUEST_CHANGES" or "COMMENT",
      "comments": [
        {
          "path": "lib/auth.ex",
          "line": 45,
          "body": "blocker: Description here"
        },
        {
          "path": "lib/auth.ex",
          "start_line": 10,
          "line": 15,
          "body": "suggestion: This whole block can be simplified\\n\\n```suggestion\\ndefp validate(token) do\\n  with {:ok, claims} <- decode(token),\\n       :ok <- check_expiry(claims) do\\n    {:ok, claims}\\n  end\\nend\\n```"
        },
        {
          "path": "lib/router.ex",
          "body": "thought: This file is getting large. Consider splitting routes into sub-modules in a follow-up."
        }
      ]
    }
    ```

    JSON field rules:
    - "path" (required): exact file path from the diff
    - "line" (required for inline): the line number in the NEW file (right side of diff)
    - "start_line" (optional): for multi-line comments, the first line of the range
    - "body" (required): the comment text with tag prefix (blocker:, nit:, suggestion:, etc.)
    - If "line" is omitted, it becomes a file-level comment (about the file in general)
    - For suggested changes, include a ```suggestion``` block inside the body (escaped newlines in JSON)
    - GitHub renders suggestion blocks with a one-click "Apply" button
    """
  end

  @doc "Post a review to GitHub with inline comments."
  def post_review(pr_number, review_json, workspace) do
    try do
      case parse_review_json(review_json) do
        {:ok, %{"summary" => summary, "verdict" => verdict, "comments" => comments}} ->
          event = case verdict do
            "APPROVE" -> "APPROVE"
            "REQUEST_CHANGES" -> "REQUEST_CHANGES"
            _ -> "COMMENT"
          end

          # Split into inline comments and file-level comments
          {inline_comments, file_comments} = Enum.split_with(comments, fn c ->
            c["line"] != nil
          end)

          # Build inline comments with multi-line support
          api_comments = Enum.map(inline_comments, fn c ->
            comment = %{
              path: c["path"],
              line: c["line"],
              body: c["body"]
            }

            # Add start_line for multi-line comments
            comment = if c["start_line"] && c["start_line"] != c["line"] do
              comment
              |> Map.put(:start_line, c["start_line"])
              |> Map.put(:start_side, "RIGHT")
              |> Map.put(:side, "RIGHT")
            else
              comment
            end

            comment
          end)

          # Append file-level comments to the summary
          file_notes = file_comments
            |> Enum.map(fn c -> "**#{c["path"]}**: #{c["body"]}" end)
            |> Enum.join("\n\n")

          full_summary = if file_notes != "" do
            summary <> "\n\n---\n\n### File-level notes\n\n" <> file_notes
          else
            summary
          end

          payload = %{
            body: full_summary,
            event: event,
            comments: api_comments
          }

          payload_json = Jason.encode!(payload)

          # Get repo info from gh
          case System.cmd("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cd: workspace, stderr_to_stdout: true) do
            {repo, 0} ->
              repo = String.trim(repo)
              case System.cmd("gh", ["api", "repos/#{repo}/pulls/#{pr_number}/reviews", "--method", "POST", "--input", "-"],
                cd: workspace, stderr_to_stdout: true, input: payload_json) do
                {_result, 0} -> {:ok, %{verdict: event, comments: length(comments)}}
                {err, _} -> {:error, "Failed to post review: #{err}"}
              end
            {err, _} -> {:error, "Failed to get repo info: #{err}"}
          end

        {:error, reason} -> {:error, reason}
      end
    catch
      kind, reason ->
        {:error, "Review posting failed: #{inspect(kind)}: #{inspect(reason)}"}
    end
  end

  @doc "Check if previous review comments have been addressed."
  def check_review(pr_number, opts \\ []) do
    _opts = opts
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())

    case check_gh() do
      {:error, _} = err -> err
      :ok ->
        try do
          # Get previous review comments
          case System.cmd("gh", ["api", "repos/{owner}/{repo}/pulls/#{pr_number}/reviews", "--jq", ".[].body"], cd: workspace, stderr_to_stdout: true) do
            {reviews, 0} ->
              # Get current diff
              case fetch_pr_diff(pr_number, workspace) do
                {:ok, diff} ->
                  {:ok, %{previous_reviews: reviews, current_diff: diff}}
                err -> err
              end
            {err, _} -> {:error, err}
          end
        catch
          kind, reason ->
            {:error, "Check review failed: #{inspect(kind)}: #{inspect(reason)}"}
        end
    end
  end

  defp parse_review_json(text) do
    # Extract JSON block from the agent output
    case Regex.run(~r/```json\s*\n(.*?)\n```/s, text) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, "Invalid JSON in review output"}
        end
      nil ->
        # Try parsing the whole text as JSON
        case Jason.decode(text) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, "No JSON review block found in agent output"}
        end
    end
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

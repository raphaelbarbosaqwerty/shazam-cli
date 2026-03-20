defmodule Shazam.GitContext do
  @moduledoc """
  Pure utility module that extracts git information and formats it
  for injection into agent prompts. NOT a GenServer.

  All functions accept a workspace path and shell out to `git` via
  `System.cmd/3`. Returns "" gracefully when the workspace is not a
  git repo or git is not installed.
  """

  @max_context_chars 500

  # ── Public API ────────────────────────────────────────

  @doc """
  Build a formatted git context string for prompt injection.
  Returns "" if not a git repo or git is unavailable.
  """
  @spec build_context(String.t() | nil) :: String.t()
  def build_context(nil), do: ""

  def build_context(workspace) do
    if git_repo?(workspace) do
      branch = current_branch(workspace)
      status = modified_files(workspace)
      commits = recent_commits(workspace, 5)
      changes = recent_changes(workspace)

      sections = ["## Git Context"]

      sections = if branch != "", do: sections ++ ["Branch: #{branch}"], else: sections

      sections = if status != [] do
        {modified, untracked} = Enum.split_with(status, fn {type, _} -> type != "new" end)
        summary = "Status: #{length(modified)} modified, #{length(untracked)} untracked"
        sections ++ [summary]
      else
        sections
      end

      sections = if commits != [] do
        commit_lines = Enum.map(commits, fn c ->
          "  - #{c.hash} \"#{c.message}\" (#{c.time_ago})"
        end)
        sections ++ ["Recent commits:" | commit_lines]
      else
        sections
      end

      sections = if status != [] do
        file_lines = Enum.map(status, fn {type, path} ->
          label = if type == "new", do: "new", else: "modified"
          "  - #{path} (#{label})"
        end)
        sections ++ ["Modified files:" | file_lines]
      else
        sections
      end

      # Also append recent changes if any
      sections = if changes != [] do
        change_lines = Enum.map(changes, fn {file, author} ->
          "  - #{file} (#{author})"
        end)
        sections ++ ["Recently changed by team:" | change_lines]
      else
        sections
      end

      result = Enum.join(sections, "\n")

      if String.length(result) > @max_context_chars do
        String.slice(result, 0, @max_context_chars) <> "\n[...truncated]"
      else
        result
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  @doc "Returns the current branch name, or \"\" if unavailable."
  @spec current_branch(String.t() | nil) :: String.t()
  def current_branch(nil), do: ""

  def current_branch(workspace) do
    case git_cmd(["rev-parse", "--abbrev-ref", "HEAD"], workspace) do
      {:ok, output} -> String.trim(output)
      _ -> ""
    end
  end

  @doc "Returns last N commits as a list of maps with :hash, :message, :author, :time_ago."
  @spec recent_commits(String.t() | nil, non_neg_integer()) :: list(map())
  def recent_commits(workspace, n \\ 5)
  def recent_commits(nil, _n), do: []

  def recent_commits(workspace, n) do
    format = "%h\x1f%s\x1f%an\x1f%ar"

    case git_cmd(["log", "--oneline", "--format=#{format}", "-n", to_string(n)], workspace) do
      {:ok, output} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          case String.split(line, "\x1f") do
            [hash, message, author, time_ago | _] ->
              %{hash: hash, message: String.slice(message, 0..60), author: author, time_ago: time_ago}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  @doc "Returns a list of {type, path} tuples from git status. Type is \"modified\", \"new\", etc."
  @spec modified_files(String.t() | nil) :: list({String.t(), String.t()})
  def modified_files(nil), do: []

  def modified_files(workspace) do
    case git_cmd(["status", "--porcelain"], workspace) do
      {:ok, output} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          status_code = String.slice(line, 0, 2) |> String.trim()
          file_path = String.slice(line, 3..-1//1) |> String.trim()

          type =
            case status_code do
              "??" -> "new"
              "M" -> "modified"
              "MM" -> "modified"
              "A" -> "added"
              "AM" -> "added"
              "D" -> "deleted"
              "R" -> "renamed"
              _ -> "modified"
            end

          {type, file_path}
        end)

      _ ->
        []
    end
  end

  @doc "Returns files changed in recent commits with who changed them. List of {file, author}."
  @spec recent_changes(String.t() | nil) :: list({String.t(), String.t()})
  def recent_changes(nil), do: []

  def recent_changes(workspace) do
    # Get files changed in last 5 commits with their authors
    case git_cmd(["log", "--name-only", "--format=%an", "-n", "5"], workspace) do
      {:ok, output} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> parse_name_only_log()
        |> Enum.uniq_by(fn {file, _} -> file end)
        |> Enum.take(10)

      _ ->
        []
    end
  end

  # ── Private Helpers ──────────────────────────────────

  defp git_repo?(workspace) do
    case git_cmd(["rev-parse", "--is-inside-work-tree"], workspace) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp git_cmd(args, workspace) do
    try do
      case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {error, _code} -> {:error, error}
      end
    rescue
      _ -> {:error, :cmd_failed}
    catch
      _, _ -> {:error, :cmd_failed}
    end
  end

  defp parse_name_only_log(lines) do
    # Format is: author line, then empty line, then file lines, repeat
    parse_name_only_log(lines, nil, [])
  end

  defp parse_name_only_log([], _current_author, acc), do: Enum.reverse(acc)

  defp parse_name_only_log(["" | rest], current_author, acc) do
    parse_name_only_log(rest, current_author, acc)
  end

  defp parse_name_only_log([line | rest], current_author, acc) do
    # Heuristic: if the line looks like a file path (contains / or .), treat it as a file
    if current_author != nil and (String.contains?(line, "/") or String.contains?(line, ".")) do
      parse_name_only_log(rest, current_author, [{line, current_author} | acc])
    else
      # It's an author name
      parse_name_only_log(rest, line, acc)
    end
  end
end

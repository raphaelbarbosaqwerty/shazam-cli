defmodule Shazam.QAManager do
  @moduledoc "Manages QA checklists, test case generation, and validation tracking."

  @qa_dir ".shazam/qa"

  def qa_dir do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    Path.join(workspace, @qa_dir)
  end

  def ensure_dir do
    dir = qa_dir()
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "reports"))
    dir
  end

  @doc "Generate a QA doc for a completed task."
  def generate_qa_doc(task) do
    dir = ensure_dir()
    slug = task.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0..40)

    filename = "#{task.id}-#{slug}.md"
    path = Path.join(dir, filename)

    # Don't overwrite existing QA docs
    unless File.exists?(path) do
      content = render_qa_doc(task)
      File.write!(path, content)
      update_readme()
      {:ok, path}
    else
      {:ok, path}
    end
  end

  @doc "List all QA docs with their status."
  def list_docs do
    dir = qa_dir()
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn f -> String.ends_with?(f, ".md") and f != "README.md" end)
      |> Enum.map(fn f ->
        path = Path.join(dir, f)
        case File.read(path) do
          {:ok, content} ->
            meta = parse_frontmatter(content)
            total = count_checkboxes(content)
            checked = count_checked(content)
            %{
              file: f,
              task_id: meta["task_id"],
              title: meta["title"] || f,
              status: meta["status"] || "pending_qa",
              total: total,
              checked: checked
            }
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc "Build a prompt for the QA agent to validate a task."
  def build_qa_prompt(task, qa_doc_path) do
    qa_content = case File.read(qa_doc_path) do
      {:ok, content} -> content
      _ -> ""
    end

    """
    You are validating the implementation of task: "#{task.title}"

    ## QA Checklist
    #{qa_content}

    ## Instructions
    1. Read the code that was implemented for this task
    2. For each test case in the checklist, verify if it works:
       - Use Read to check the code
       - Use Bash to run any existing tests (look for test files, playwright, jest, etc.)
       - Use Grep to find the implementation
    3. Mark each checkbox:
       - [x] if the test passes
       - [ ] if the test fails — add a note explaining why
    4. At the end, output the updated checklist with all checkboxes marked
    5. If any test fails, output a bug report in this format:

    ```bugs
    [
      {"title": "Bug: [description]", "test_case": "TC-XX", "details": "What failed and why", "file": "path/to/file.ex", "line": 42}
    ]
    ```

    6. If all tests pass, output: ALL_TESTS_PASSED
    """
  end

  @doc "Generate a daily QA report."
  def generate_report do
    dir = ensure_dir()
    docs = list_docs()

    date = Date.to_string(Date.utc_today())
    total_docs = length(docs)
    passed = Enum.count(docs, fn d -> d.checked == d.total and d.total > 0 end)
    pending = Enum.count(docs, fn d -> d.checked < d.total end)

    report = """
    # QA Report — #{date}

    **Total:** #{total_docs} | **Passed:** #{passed} | **Pending:** #{pending}

    ## Details

    #{docs |> Enum.map(fn d ->
      progress = if d.total > 0, do: "#{d.checked}/#{d.total}", else: "no tests"
      status_icon = cond do
        d.total == 0 -> "○"
        d.checked == d.total -> "✓"
        true -> "…"
      end
      "| #{status_icon} | #{d.task_id} | #{d.title} | #{progress} |"
    end) |> Enum.join("\n")}
    """

    path = Path.join([dir, "reports", "#{date}.md"])
    File.write!(path, report)
    {:ok, path}
  end

  # ── Private ──────────────────────────────────────────────

  defp render_qa_doc(task) do
    developer = task.assigned_to || "unknown"
    result = if is_binary(task.result), do: String.slice(task.result, 0..2000), else: ""
    title = task.title || "Untitled"

    """
    ---
    task_id: #{task.id}
    title: "#{String.replace(title, "\"", "\\\"")}"
    status: pending_qa
    developer: #{developer}
    created_at: #{DateTime.to_iso8601(DateTime.utc_now())}
    ---

    # QA — #{title}

    Validation of implementation by #{developer}.

    ## Implementation Context

    #{result}

    ## Test Cases

    ### TC-01 — Basic Functionality
    | # | Action | Expected Result | Status |
    |---|--------|----------------|--------|
    | 1 | Verify the feature was implemented | Code exists and compiles | [ ] |
    | 2 | Run related tests if they exist | Tests pass | [ ] |
    | 3 | Check for error handling | Errors handled gracefully | [ ] |

    ### TC-02 — Edge Cases
    | # | Action | Expected Result | Status |
    |---|--------|----------------|--------|
    | 1 | Test with empty/null inputs | No crashes | [ ] |
    | 2 | Test with invalid data | Proper validation | [ ] |

    ### TC-03 — Code Quality
    | # | Action | Expected Result | Status |
    |---|--------|----------------|--------|
    | 1 | No hardcoded values | Uses config/constants | [ ] |
    | 2 | Follows project conventions | Consistent with codebase | [ ] |
    | 3 | No security vulnerabilities | Input sanitized | [ ] |

    ## Regression Checklist
    - [ ] Feature works as described
    - [ ] No console errors
    - [ ] Existing tests still pass
    - [ ] No performance regression
    - [ ] Responsive/cross-browser (if UI)

    ## Bugs Found
    <!-- QA agent fills this section -->

    ## Result
    <!-- PASSED or FAILED with details -->
    """
  end

  defp update_readme do
    dir = qa_dir()
    docs = list_docs()

    content = """
    # QA — Test Cases

    | Status | Task | Title | Progress |
    |--------|------|-------|----------|
    #{docs |> Enum.map(fn d ->
      icon = cond do
        d.total == 0 -> "○"
        d.checked == d.total -> "✅"
        d.checked > 0 -> "🔄"
        true -> "⏳"
      end
      "| #{icon} | #{d.task_id} | #{d.title} | #{d.checked}/#{d.total} |"
    end) |> Enum.join("\n")}
    """

    File.write!(Path.join(dir, "README.md"), content)
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, fm] ->
        fm |> String.split("\n") |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ": ", parts: 2) do
            [k, v] -> Map.put(acc, String.trim(k), String.trim(v) |> String.trim("\""))
            _ -> acc
          end
        end)
      _ -> %{}
    end
  end

  defp count_checkboxes(content) do
    Regex.scan(~r/\[ \]|\[x\]/i, content) |> length()
  end

  defp count_checked(content) do
    Regex.scan(~r/\[x\]/i, content) |> length()
  end
end

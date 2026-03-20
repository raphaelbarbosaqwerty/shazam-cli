defmodule Shazam.CLI.TuiPort.Commands.Review do
  @moduledoc """
  PR Review commands: /review and all its sub-flags
  (--post, --check, --resolve, --learn, --patterns, etc.)
  """

  alias Shazam.CLI.TuiPort.{Helpers, Status}

  def handle_command("/review " <> rest, state) do
    args = String.trim(rest)
    company_name = Helpers.deep_get(state, [:company, :name])

    try do
      cond do
        args == "--learn" ->
          Helpers.send_event(state.port, "system", "info", "Learning from recent PR reviews...")
          case Shazam.PRReviewer.learn() do
            {:ok, count} ->
              Helpers.send_event(state.port, "system", "info", "Learned #{count} patterns from merged PRs")
            {:error, reason} ->
              Helpers.send_event(state.port, "system", "error", "Failed to learn: #{inspect(reason)}")
          end

        args == "--patterns" ->
          patterns = Shazam.PRReviewer.patterns()
          if patterns == "" do
            Helpers.send_event(state.port, "system", "info", "No review patterns learned yet. Run /review --learn")
          else
            lines = String.split(patterns, "\n") |> Enum.take(20)
            Enum.each(lines, fn line ->
              Helpers.send_event(state.port, "system", "info", line)
            end)
          end

        String.starts_with?(args, "--post ") ->
          task_id = String.trim_leading(args, "--post ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Posting review to GitHub...")

          try do
            if Code.ensure_loaded?(Shazam.TaskBoard) do
              case Shazam.TaskBoard.get(task_id) do
                {:ok, task} when not is_nil(task.result) ->
                  # Extract PR number from title "Review PR #42"
                  pr_number = case Regex.run(~r/PR #(\d+)/, task.title) do
                    [_, num] -> num
                    _ -> nil
                  end

                  if pr_number do
                    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
                    case Shazam.PRReviewer.post_review(pr_number, task.result, workspace) do
                      {:ok, %{verdict: verdict, comments: count}} ->
                        Helpers.send_event(state.port, "reviewer", "info", "Review posted: #{verdict} with #{count} inline comments")
                      {:error, reason} ->
                        Helpers.send_event(state.port, "system", "error", "Failed to post: #{inspect(reason)}")
                    end
                  else
                    Helpers.send_event(state.port, "system", "error", "Could not extract PR number from task title")
                  end
                {:ok, _} ->
                  Helpers.send_event(state.port, "system", "error", "Task has no result yet. Wait for the reviewer to complete.")
                _ ->
                  Helpers.send_event(state.port, "system", "error", "Task #{task_id} not found")
              end
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Post review error: #{inspect(kind)}: #{inspect(reason)}")
          end

        String.starts_with?(args, "--check ") ->
          pr_number = String.trim_leading(args, "--check ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Checking if PR ##{pr_number} changes were addressed...")

          try do
            case Shazam.PRReviewer.check_review(pr_number) do
              {:ok, context} ->
                reviewer_profile = find_reviewer_agent(state)
                reviewer_name = reviewer_profile[:name] || Helpers.find_pm_name(state)

                prompt = """
                Check if the previous review comments have been addressed in the latest diff.

                Previous reviews:
                #{context.previous_reviews}

                Current diff:
                ```diff
                #{String.slice(context.current_diff, 0..8000)}
                ```

                For each previous comment, check if it was addressed. If all addressed, verdict APPROVE. If not, REQUEST_CHANGES with remaining issues.

                #{Shazam.PRReviewer.build_review_prompt(%{pr_number: pr_number, pr_info: "", diff: context.current_diff, files: [], file_contexts: [], patterns: ""}) |> String.split("IMPORTANT:") |> List.last()}
                """

                if Code.ensure_loaded?(Shazam.TaskBoard) do
                  Shazam.TaskBoard.create(%{
                    title: "Re-review PR ##{pr_number}",
                    assigned_to: reviewer_name,
                    created_by: "human",
                    company: Helpers.deep_get(state, [:company, :name]),
                    description: String.slice(prompt, 0..15_000)
                  })
                  Helpers.send_event(state.port, reviewer_name, "task_created", "Re-review task for PR ##{pr_number}")
                end
              {:error, reason} ->
                Helpers.send_event(state.port, "system", "error", "Check failed: #{inspect(reason)}")
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Check review error: #{inspect(kind)}: #{inspect(reason)}")
          end

        String.starts_with?(args, "--resolve ") ->
          pr_number = String.trim_leading(args, "--resolve ") |> String.trim()
          Helpers.send_event(state.port, "reviewer", "info", "Resolving threads on PR ##{pr_number}...")

          try do
            case Shazam.PRReviewer.resolve_threads(pr_number) do
              {:ok, count} ->
                Helpers.send_event(state.port, "reviewer", "info", "Resolved #{count} conversation threads")
              {:error, reason} ->
                Helpers.send_event(state.port, "system", "error", "Failed to resolve: #{inspect(reason)}")
            end
          catch
            kind, reason ->
              Helpers.send_event(state.port, "system", "error", "Resolve error: #{inspect(kind)}: #{inspect(reason)}")
          end

        true ->
          Helpers.send_event(state.port, "reviewer", "info", "Reviewing PR ##{args}...")

          case Shazam.PRReviewer.review(args) do
            {:ok, context} ->
              Helpers.send_event(state.port, "reviewer", "info", "Building review prompt (#{length(context.files)} files)...")
              prompt = Shazam.PRReviewer.build_review_prompt(context)
              # Truncate prompt to avoid oversized tasks
              prompt = String.slice(prompt, 0..15_000)
              reviewer_profile = find_reviewer_agent(state)
              reviewer_name = reviewer_profile[:name] || Helpers.find_pm_name(state)
              Helpers.send_event(state.port, "reviewer", "info", "Assigning to #{reviewer_name}...")

              if Code.ensure_loaded?(Shazam.TaskBoard) do
                Shazam.TaskBoard.create(%{
                  title: "Review PR ##{args}",
                  assigned_to: reviewer_name,
                  created_by: "human",
                  company: company_name,
                  description: prompt
                })
                Helpers.send_event(state.port, reviewer_name, "task_created", "PR ##{args} review task created")
              end

            {:error, reason} ->
              Helpers.send_event(state.port, "system", "error", "Review failed: #{inspect(reason)}")
          end
      end
    rescue
      e ->
        Helpers.send_event(state.port, "system", "error", "Review error: #{inspect(e)}")
    catch
      kind, reason ->
        Helpers.send_event(state.port, "system", "error", "Review error: #{inspect(kind)}: #{inspect(reason)}")
    end

    Status.send_status(state)
    state
  end

  defp find_reviewer_agent(state) do
    agents = Helpers.deep_get(state, [:company, :agents]) ||
             Helpers.deep_get(state, [:company, :config, :agents]) || []

    case Enum.find(agents, fn a ->
      role = String.downcase(a[:role] || "")
      String.contains?(role, "review")
    end) do
      nil ->
        # Use PM as fallback if no reviewer exists
        pm_name = Helpers.find_pm_name(state)
        %{name: pm_name, role: "Project Manager"}
      agent ->
        agent
    end
  end
end

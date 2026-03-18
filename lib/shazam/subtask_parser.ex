defmodule Shazam.SubtaskParser do
  @moduledoc """
  Subtask parsing and creation logic extracted from RalphLoop.
  Handles parsing PM/agent output for subtask JSON blocks and creating them in TaskBoard.
  """

  require Logger

  alias Shazam.TaskBoard

  @doc "Try to parse and create subtasks from agent output."
  def maybe_create_subtasks(parent_task_id, agent_name, output, company_name, auto_approve) do
    # Any agent can generate subtasks if they output the right format.
    # PMs always do this; designers do it after Figma analysis; others can too.
    agents = try do
      Shazam.Company.get_agents(company_name)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end

    if agents != [] do
      parse_and_create_subtasks(parent_task_id, agent_name, output, agents, company_name, auto_approve)
    end
  end

  @doc "Parse subtasks JSON from output and create them in TaskBoard."
  def parse_and_create_subtasks(parent_task_id, pm_name, output, agents, company_name, auto_approve) do
    # Look for JSON block with sub-tasks in the PM output
    case extract_subtasks_json(output) do
      {:ok, subtasks} ->
        Logger.info("[RalphLoop] #{pm_name} generated #{length(subtasks)} sub-task(s) (auto_approve=#{auto_approve})")

        Enum.each(subtasks, fn subtask ->
          assigned = subtask["assigned_to"]
          depends = subtask["depends_on"]

          # Validate that the agent exists
          agent_exists = Enum.any?(agents, &(&1.name == assigned))

          if agent_exists do
            # Auto-approve: create as pending directly (no manual approval needed)
            # Otherwise: create as awaiting_approval
            {:ok, created} = if auto_approve do
              TaskBoard.create(%{
                title: subtask["title"],
                description: subtask["description"],
                assigned_to: assigned,
                created_by: pm_name,
                parent_task_id: parent_task_id,
                depends_on: depends,
                company: company_name
              })
            else
              TaskBoard.create_awaiting(%{
                title: subtask["title"],
                description: subtask["description"],
                assigned_to: assigned,
                created_by: pm_name,
                parent_task_id: parent_task_id,
                depends_on: depends,
                company: company_name
              })
            end

            status_label = if auto_approve, do: "pending", else: "awaiting approval"
            Logger.info("[RalphLoop] Sub-task #{created.id}: '#{subtask["title"]}' → #{assigned} (#{status_label})")
          else
            Logger.warning("[RalphLoop] Agent '#{assigned}' not found, ignoring sub-task '#{subtask["title"]}'")
          end
        end)

      :no_subtasks ->
        Logger.debug("[RalphLoop] No sub-tasks found in PM output")
    end
  end

  @doc "Extract subtasks JSON from agent output text."
  def extract_subtasks_json(output) when is_binary(output) do
    # Look for ```json ... ``` or ```subtasks ... ``` block
    regex = ~r/```(?:json|subtasks)?\s*\n(\[[\s\S]*?\])\s*\n```/

    case Regex.run(regex, output) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> :no_subtasks
        end

      nil ->
        # Try directly as JSON if it starts with [
        trimmed = String.trim(output)
        if String.starts_with?(trimmed, "[") do
          case Jason.decode(trimmed) do
            {:ok, list} when is_list(list) -> {:ok, list}
            _ -> :no_subtasks
          end
        else
          :no_subtasks
        end
    end
  end

  def extract_subtasks_json(_), do: :no_subtasks
end

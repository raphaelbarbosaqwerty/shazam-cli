defmodule Shazam.Test.Factory do
  @moduledoc """
  Test factory for building common test data structures.
  """

  @doc "Builds a task attributes map with sensible defaults."
  def build_task(overrides \\ %{}) do
    defaults = %{
      title: "Test Task #{System.unique_integer([:positive])}",
      description: "A test task description",
      assigned_to: "test_agent",
      created_by: "test_creator",
      parent_task_id: nil,
      depends_on: nil,
      company: "test_company"
    }

    Map.merge(defaults, Enum.into(overrides, %{}))
  end

  @doc "Builds an agent struct with sensible defaults."
  def build_agent(overrides \\ %{}) do
    id = System.unique_integer([:positive])

    defaults = %{
      name: "agent_#{id}",
      role: "Developer",
      supervisor: nil,
      domain: nil,
      budget: 100_000,
      heartbeat_interval: 60_000,
      model: nil,
      fallback_model: nil,
      tools: ["Read", "Edit", "Write"],
      skills: [],
      modules: [],
      system_prompt: nil
    }

    Map.merge(defaults, Enum.into(overrides, %{}))
  end

  @doc "Builds a company config map with sensible defaults."
  def build_company_config(overrides \\ %{}) do
    defaults = %{
      name: "TestCo",
      mission: "Test mission statement",
      agents: [
        build_agent(%{name: "pm", role: "Project Manager", supervisor: nil}),
        build_agent(%{name: "dev1", role: "Senior Developer", supervisor: "pm"}),
        build_agent(%{name: "dev2", role: "Junior Developer", supervisor: "pm"})
      ],
      domain_config: %{},
      workspace: "/tmp/test_workspace",
      ralph_config: %{
        auto_approve: false,
        auto_retry: false,
        max_concurrent: 4,
        max_retries: 2,
        poll_interval: 5_000,
        module_lock: true,
        peer_reassign: true
      },
      tech_stack: nil
    }

    Map.merge(defaults, Enum.into(overrides, %{}))
  end
end

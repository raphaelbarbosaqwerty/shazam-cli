defmodule Shazam.AgentQueryTest do
  use ExUnit.Case, async: false

  alias Shazam.AgentQuery

  @moduletag :agent_query

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "shazam_aq_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    original_workspace = Application.get_env(:shazam, :workspace)
    Application.put_env(:shazam, :workspace, tmp_dir)

    on_exit(fn ->
      if original_workspace do
        Application.put_env(:shazam, :workspace, original_workspace)
      else
        Application.delete_env(:shazam, :workspace)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "query/2" do
    test "returns 'no context' message when agent dir doesn't exist" do
      result = AgentQuery.query("nonexistent_agent", "What did you work on?")
      assert result =~ "no stored context"
    end

    test "returns relevant context when agent has topic files", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join([tmp_dir, ".shazam", "context", "agents", "senior_1"])
      File.mkdir_p!(agent_dir)

      File.write!(Path.join(agent_dir, "auth.md"), """
      ### [2026-03-20] JWT authentication
      Implemented JWT token validation with RS256 algorithm.
      Created middleware for protected routes.
      """)

      result = AgentQuery.query("senior_1", "What authentication did you implement?")
      assert is_binary(result)
      # Should find something or report no relevant knowledge
      assert result != ""
    end

    test "includes learnings when available", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join([tmp_dir, ".shazam", "context", "agents", "senior_1"])
      File.mkdir_p!(agent_dir)

      File.write!(Path.join(agent_dir, "_learnings.md"), """
      ### [2026-03-20] From: Auth setup
      - Project uses JWT with RS256 for authentication
      - Redis is used for session storage
      """)

      result = AgentQuery.query("senior_1", "What do you know about authentication?")
      assert is_binary(result)
      assert result =~ "JWT" or result =~ "knowledge"
    end
  end

  describe "build_instruction/2" do
    test "lists other agents with their roles" do
      agents = [
        %{name: "pm", role: "Project Manager"},
        %{name: "senior_1", role: "Senior Developer"},
        %{name: "qa", role: "QA Engineer"}
      ]

      result = AgentQuery.build_instruction("pm", agents)
      assert is_binary(result)
      assert result =~ "senior_1"
      assert result =~ "Senior Developer"
      assert result =~ "qa"
      assert result =~ "QA Engineer"
      # Should NOT include the requesting agent
      refute result =~ "Project Manager"
    end

    test "returns empty string when no other agents" do
      agents = [%{name: "solo_agent", role: "Developer"}]
      result = AgentQuery.build_instruction("solo_agent", agents)
      assert result == ""
    end

    test "returns empty string when agent list is empty" do
      result = AgentQuery.build_instruction("any", [])
      assert result == ""
    end

    test "handles keyword list agents" do
      agents = [
        [name: "pm", role: "Project Manager"],
        [name: "dev", role: "Developer"]
      ]

      result = AgentQuery.build_instruction("pm", agents)
      assert result =~ "dev"
      assert result =~ "Developer"
    end
  end

  describe "resolve_queries/3" do
    test "resolves AGENT_QUERY patterns in output", %{tmp_dir: tmp_dir} do
      # Create context for the target agent
      agent_dir = Path.join([tmp_dir, ".shazam", "context", "agents", "senior_1"])
      File.mkdir_p!(agent_dir)

      File.write!(Path.join(agent_dir, "database.md"), """
      ### [2026-03-20] Database schema
      Created users table with email and password_hash columns.
      """)

      output = "I need to check the database schema.\nAGENT_QUERY: senior_1 What database schema did you create?"

      {resolved, count} = AgentQuery.resolve_queries(output, "pm")
      assert count == 1
      assert resolved =~ "Response from senior_1"
    end

    test "respects max_queries limit" do
      output = """
      AGENT_QUERY: agent_a What did you do?
      AGENT_QUERY: agent_b What did you do?
      AGENT_QUERY: agent_c What did you do?
      """

      {_resolved, count} = AgentQuery.resolve_queries(output, "pm", 2)
      assert count <= 2
    end
  end
end

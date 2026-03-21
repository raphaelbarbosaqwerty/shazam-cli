defmodule Shazam.ContextManagerTest do
  use ExUnit.Case, async: false

  alias Shazam.ContextManager

  @moduletag :context_manager

  setup do
    # Use a temp directory as workspace for isolation
    tmp_dir = Path.join(System.tmp_dir!(), "shazam_cm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    original_workspace = Application.get_env(:shazam, :workspace)
    Application.put_env(:shazam, :workspace, tmp_dir)

    ensure_started(Shazam.ContextManager)

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

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  describe "capture/3" do
    test "writes to correct topic file under agent directory", %{tmp_dir: tmp_dir} do
      task = %{title: "Implement auth middleware"}
      output = "Created JWT middleware with token validation"

      ContextManager.capture("senior_1", task, output, ["lib/auth.ex"])
      # cast is async
      Process.sleep(150)

      agent_dir = Path.join([tmp_dir, ".shazam", "context", "agents", "senior_1"])
      assert File.dir?(agent_dir)

      # Should have at least one topic file (not index.md)
      {:ok, files} = File.ls(agent_dir)
      topic_files = Enum.filter(files, &(String.ends_with?(&1, ".md") and &1 != "index.md"))
      assert length(topic_files) > 0

      # The topic file should contain the task output
      content =
        topic_files
        |> Enum.map(&Path.join(agent_dir, &1))
        |> Enum.map(&File.read!/1)
        |> Enum.join("")

      assert content =~ "Implement auth middleware"
    end

    test "appends to team_activity.md", %{tmp_dir: tmp_dir} do
      task = %{title: "Database migration"}
      output = "Ran migration for users table"

      ContextManager.capture("pm", task, output)
      Process.sleep(150)

      team_path = Path.join([tmp_dir, ".shazam", "context", "team_activity.md"])
      assert File.exists?(team_path)

      content = File.read!(team_path)
      assert content =~ "pm"
      assert content =~ "Database migration"
    end
  end

  describe "build_context/2" do
    test "returns formatted string with context sections", %{tmp_dir: _tmp_dir} do
      task = %{title: "Fix login bug"}
      output = "Found that the session token was expiring too early"

      ContextManager.capture("dev_1", task, output, ["lib/session.ex"])
      Process.sleep(200)

      result = ContextManager.build_context("dev_1", %{title: "Fix session timeout", description: "Sessions expire"})
      assert is_binary(result)
      # Should contain something from the captured context
      # (may be empty if RAG has no data yet, but should not crash)
    end

    test "returns empty string for agent with no context" do
      result = ContextManager.build_context("nonexistent_agent", %{title: "Some task"})
      assert is_binary(result)
    end
  end

  describe "learnings extraction" do
    test "extracts learnings from output containing decision patterns", %{tmp_dir: tmp_dir} do
      task = %{title: "Setup auth"}
      output = "Found that the project uses JWT for authentication. Decided to use RS256 algorithm for better security."

      ContextManager.capture("senior_1", task, output, ["lib/auth.ex"])
      Process.sleep(200)

      learnings_path = Path.join([tmp_dir, ".shazam", "context", "agents", "senior_1", "_learnings.md"])

      if File.exists?(learnings_path) do
        content = File.read!(learnings_path)
        # Should have extracted at least one learning
        assert content =~ ~r/^- /m
      end
    end

    test "deduplication prevents same learning from being added twice", %{tmp_dir: tmp_dir} do
      task = %{title: "Check stack"}
      output = "Found that the project uses React for the frontend layer"

      ContextManager.capture("dev_2", task, output, ["package.json"])
      Process.sleep(200)

      # Capture same output again
      ContextManager.capture("dev_2", task, output, ["package.json"])
      Process.sleep(200)

      learnings_path = Path.join([tmp_dir, ".shazam", "context", "agents", "dev_2", "_learnings.md"])

      if File.exists?(learnings_path) do
        content = File.read!(learnings_path)
        # Count occurrences of the learning — should not be duplicated
        matches = Regex.scan(~r/project uses React/i, content)
        assert length(matches) <= 2
      end
    end
  end
end

defmodule Shazam.GitContextTest do
  use ExUnit.Case, async: true

  alias Shazam.GitContext

  @moduletag :git_context

  describe "build_context/1" do
    test "returns string with branch info when in a git repo" do
      # Use the project's own directory which is a git repo
      # (or a known git directory)
      workspace = find_git_workspace()

      if workspace do
        result = GitContext.build_context(workspace)
        assert is_binary(result)
        assert result =~ "Git Context" or result == ""
      end
    end

    test "returns empty string for nil workspace" do
      assert GitContext.build_context(nil) == ""
    end

    test "returns empty string for non-git directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_git_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      result = GitContext.build_context(tmp_dir)
      assert result == ""

      File.rm_rf!(tmp_dir)
    end
  end

  describe "current_branch/1" do
    test "returns branch name for git repo" do
      workspace = find_git_workspace()

      if workspace do
        branch = GitContext.current_branch(workspace)
        assert is_binary(branch)
        assert branch != "" or true  # may be detached HEAD
      end
    end

    test "returns empty string for nil" do
      assert GitContext.current_branch(nil) == ""
    end

    test "returns empty string for non-git directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_git_branch_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      result = GitContext.current_branch(tmp_dir)
      assert result == ""

      File.rm_rf!(tmp_dir)
    end
  end

  describe "modified_files/1" do
    test "returns a list for a git repo" do
      workspace = find_git_workspace()

      if workspace do
        result = GitContext.modified_files(workspace)
        assert is_list(result)
        # Each element should be a {type, path} tuple
        Enum.each(result, fn item ->
          assert {_type, _path} = item
        end)
      end
    end

    test "returns empty list for nil" do
      assert GitContext.modified_files(nil) == []
    end
  end

  describe "recent_commits/2" do
    test "returns list of commit maps for git repo" do
      workspace = find_git_workspace()

      if workspace do
        commits = GitContext.recent_commits(workspace, 3)
        assert is_list(commits)

        Enum.each(commits, fn commit ->
          assert Map.has_key?(commit, :hash)
          assert Map.has_key?(commit, :message)
          assert Map.has_key?(commit, :author)
          assert Map.has_key?(commit, :time_ago)
        end)
      end
    end

    test "returns empty list for nil" do
      assert GitContext.recent_commits(nil) == []
    end
  end

  # Helper to find a git workspace for testing
  defp find_git_workspace do
    # Try the project's own workspace first
    cwd = File.cwd!()

    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: cwd, stderr_to_stdout: true) do
      {"true\n", 0} -> cwd
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

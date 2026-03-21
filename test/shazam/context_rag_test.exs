defmodule Shazam.ContextRAGTest do
  use ExUnit.Case, async: false

  alias Shazam.ContextRAG

  @moduletag :context_rag

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "shazam_rag_test_#{System.unique_integer([:positive])}")
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

  defp create_context_file(tmp_dir, relative_path, content) do
    full_path = Path.join([tmp_dir, ".shazam", relative_path])
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  describe "search/2" do
    test "returns results sorted by score descending", %{tmp_dir: tmp_dir} do
      create_context_file(tmp_dir, "context/agents/dev/auth.md", """
      ### [2026-03-20] JWT authentication
      Implemented JWT token validation with RS256 algorithm.
      Created middleware for Express routes.
      """)

      create_context_file(tmp_dir, "context/agents/dev/database.md", """
      ### [2026-03-20] Database setup
      Configured PostgreSQL with connection pooling.
      Ran initial migrations for users and sessions tables.
      """)

      create_context_file(tmp_dir, "context/agents/dev/api.md", """
      ### [2026-03-20] REST API endpoints
      Created CRUD endpoints for the users resource.
      Added JWT authentication middleware to protected routes.
      """)

      results = ContextRAG.search("JWT authentication middleware")

      assert is_list(results)
      assert length(results) > 0

      # Results should be {score, text} tuples sorted by score desc
      scores = Enum.map(results, fn {score, _text} -> score end)
      assert scores == Enum.sort(scores, :desc)
    end

    test "returns empty list when no context files exist", %{tmp_dir: _tmp_dir} do
      results = ContextRAG.search("anything")
      assert results == []
    end

    test "empty query returns empty list", %{tmp_dir: tmp_dir} do
      create_context_file(tmp_dir, "context/agents/dev/stuff.md", """
      ### [2026-03-20] Some work
      Did some important work here.
      """)

      # Query with only stopwords should return empty
      results = ContextRAG.search("the a an and or but")
      assert results == []
    end

    test "stopwords are removed from query", %{tmp_dir: tmp_dir} do
      create_context_file(tmp_dir, "context/agents/dev/auth.md", """
      ### [2026-03-20] Authentication system
      Implemented robust authentication with password hashing and session management.
      """)

      # "the" and "with" are stopwords, "authentication" is the real query
      results_with_stopwords = ContextRAG.search("the authentication with system")
      results_clean = ContextRAG.search("authentication system")

      # Both should find the same content
      assert length(results_with_stopwords) == length(results_clean)
    end
  end

  describe "search_formatted/2" do
    test "returns formatted string within budget", %{tmp_dir: tmp_dir} do
      # Create a file with multiple entries
      entries = Enum.map(1..10, fn i ->
        "### [2026-03-20] Task #{i}\nImplemented feature number #{i} with detailed authentication logic.\n"
      end) |> Enum.join("\n")

      create_context_file(tmp_dir, "context/agents/dev/features.md", entries)

      result = ContextRAG.search_formatted("authentication feature", budget: 200)

      assert is_binary(result)
      assert String.length(result) <= 200 + 100  # allow some margin for last chunk
    end

    test "returns empty string when no results", %{tmp_dir: _tmp_dir} do
      result = ContextRAG.search_formatted("nonexistent topic")
      assert result == ""
    end

    test "respects top_k option", %{tmp_dir: tmp_dir} do
      entries = Enum.map(1..20, fn i ->
        "### [2026-03-20] Auth task #{i}\nAuthentication work number #{i} with JWT tokens.\n"
      end) |> Enum.join("\n")

      create_context_file(tmp_dir, "context/agents/dev/auth.md", entries)

      result = ContextRAG.search_formatted("authentication JWT", budget: 50_000, top_k: 3)
      assert is_binary(result)
    end
  end
end

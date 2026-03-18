defmodule Shazam.MemoryBankTest do
  use ExUnit.Case, async: false

  alias Shazam.MemoryBank

  @test_workspace "/tmp/shazam_memory_test_#{System.unique_integer([:positive])}"

  setup do
    Application.put_env(:shazam, :workspace, @test_workspace)
    MemoryBank.init()

    on_exit(fn ->
      File.rm_rf!(Path.join(@test_workspace, ".shazam/memory"))
      Application.delete_env(:shazam, :workspace)
    end)

    :ok
  end

  # ── init/0 ───────────────────────────────────────────────

  describe "init/0" do
    test "creates the memory directory" do
      assert {:ok, dir} = MemoryBank.init()
      assert File.dir?(dir)
    end

    test "returns error when no workspace is set" do
      Application.delete_env(:shazam, :workspace)
      assert {:error, :no_workspace} = MemoryBank.init()
    end
  end

  # ── read/1 and write/2 ──────────────────────────────────

  describe "read/1 and write/2" do
    test "writes and reads memory content" do
      :ok = MemoryBank.write("test_agent", "# Memory\nSome knowledge")
      content = MemoryBank.read("test_agent")

      assert content == "# Memory\nSome knowledge"
    end

    test "read returns empty string for non-existent agent" do
      assert MemoryBank.read("nonexistent_agent") == ""
    end

    test "overwrites existing memory" do
      MemoryBank.write("overwrite_agent", "v1")
      MemoryBank.write("overwrite_agent", "v2")

      assert MemoryBank.read("overwrite_agent") == "v2"
    end

    test "write returns error when no workspace" do
      Application.delete_env(:shazam, :workspace)
      assert {:error, :no_workspace} = MemoryBank.write("agent", "content")
    end
  end

  # ── agent_path/1 ─────────────────────────────────────────

  describe "agent_path/1" do
    test "returns the correct file path" do
      path = MemoryBank.agent_path("my_agent")
      assert String.ends_with?(path, ".shazam/memory/my_agent.md")
    end

    test "returns nil when no workspace" do
      Application.delete_env(:shazam, :workspace)
      assert MemoryBank.agent_path("agent") == nil
    end
  end

  # ── delete/1 ─────────────────────────────────────────────

  describe "delete/1" do
    test "deletes an agent's memory bank" do
      MemoryBank.write("deletable", "content")
      MemoryBank.delete("deletable")

      assert MemoryBank.read("deletable") == ""
    end

    test "returns error when no workspace" do
      Application.delete_env(:shazam, :workspace)
      assert {:error, :no_workspace} = MemoryBank.delete("agent")
    end
  end

  # ── list_all/0 ───────────────────────────────────────────

  describe "list_all/0" do
    test "lists all memory banks" do
      MemoryBank.write("agent_1", "knowledge 1")
      MemoryBank.write("agent_2", "knowledge 2")

      all = MemoryBank.list_all()
      names = Enum.map(all, & &1.agent) |> Enum.sort()

      assert "agent_1" in names
      assert "agent_2" in names
    end

    test "returns empty list when no memories exist" do
      # Clean dir first
      dir = MemoryBank.memory_dir()
      if dir, do: File.rm_rf!(dir)
      MemoryBank.init()

      assert MemoryBank.list_all() == []
    end

    test "returns empty list when no workspace" do
      Application.delete_env(:shazam, :workspace)
      assert MemoryBank.list_all() == []
    end

    test "each entry has agent, content, and path" do
      MemoryBank.write("structured", "data")
      [entry | _] = MemoryBank.list_all() |> Enum.filter(&(&1.agent == "structured"))

      assert is_binary(entry.agent)
      assert is_binary(entry.content)
      assert is_binary(entry.path)
    end
  end

  # ── build_prompt/2 ──────────────────────────────────────

  describe "build_prompt/2" do
    test "returns empty string for agent with no memory" do
      prompt = MemoryBank.build_prompt("fresh_agent")
      # Should have update instructions but no memory context
      assert prompt =~ "Memory Bank Update Instructions"
    end

    test "includes memory content when present" do
      MemoryBank.write("has_memory", "# Important Facts\nElixir is great.")
      prompt = MemoryBank.build_prompt("has_memory")

      assert prompt =~ "Important Facts"
      assert prompt =~ "Elixir is great"
    end

    test "includes update instructions in full mode" do
      prompt = MemoryBank.build_prompt("any_agent", full: true)
      assert prompt =~ "Memory Bank Update Instructions"
    end

    test "omits update instructions when full: false" do
      prompt = MemoryBank.build_prompt("any_agent", full: false)
      refute prompt =~ "Memory Bank Update Instructions"
    end

    test "truncates very long memory" do
      # Use content with newlines so truncation logic can cut at line boundaries
      long_content = Enum.map_join(1..500, "\n", fn i -> "Line #{i}: some knowledge data here" end)
      MemoryBank.write("verbose", long_content)

      prompt = MemoryBank.build_prompt("verbose")
      assert prompt =~ "truncated"
    end
  end

  # ── build_onboarding_prompt/1 ───────────────────────────

  describe "build_onboarding_prompt/1" do
    test "builds a prompt listing all agents" do
      agents = [
        %{name: "dev", role: "Developer", modules: [%{"path" => "lib/"}]},
        %{name: "qa", role: "QA", modules: []}
      ]

      prompt = MemoryBank.build_onboarding_prompt(agents)
      assert prompt =~ "dev"
      assert prompt =~ "qa"
      assert prompt =~ "Developer"
      assert prompt =~ "Project Onboarding"
    end
  end
end

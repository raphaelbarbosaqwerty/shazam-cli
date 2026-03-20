defmodule Shazam.AgentConfigTest do
  use ExUnit.Case, async: false

  alias Shazam.AgentConfig

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "shazam_agent_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Point the workspace to our temp directory
    previous_workspace = Application.get_env(:shazam, :workspace)
    Application.put_env(:shazam, :workspace, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      if previous_workspace do
        Application.put_env(:shazam, :workspace, previous_workspace)
      else
        Application.delete_env(:shazam, :workspace)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ── write_agent/2 ──────────────────────────────────────────

  describe "write_agent/2" do
    test "creates .md file with correct frontmatter", %{tmp_dir: tmp_dir} do
      config = %{role: "Developer", model: "claude-sonnet-4-6", budget: 200_000, tools: ["Read", "Edit"]}
      {:ok, path} = AgentConfig.write_agent("dev1", config)

      assert File.exists?(path)
      assert path == Path.join([tmp_dir, ".shazam", "agents", "dev1.md"])

      content = File.read!(path)
      assert content =~ "---"
      assert content =~ "role: Developer"
      assert content =~ "model: claude-sonnet-4-6"
      assert content =~ "budget: 200000"
      assert content =~ "tools: [Read, Edit]"
    end

    test "includes system prompt in body", %{tmp_dir: _tmp_dir} do
      config = %{role: "QA", system_prompt: "You are a QA engineer."}
      {:ok, path} = AgentConfig.write_agent("qa", config)

      content = File.read!(path)
      assert content =~ "You are a QA engineer."
    end

    test "writes file without model when model is nil" do
      config = %{role: "Agent", budget: 100_000, tools: []}
      {:ok, path} = AgentConfig.write_agent("basic", config)

      content = File.read!(path)
      refute content =~ "model:"
    end

    test "writes file without tools when tools list is empty" do
      config = %{role: "Agent", budget: 50_000, tools: []}
      {:ok, path} = AgentConfig.write_agent("notool", config)

      content = File.read!(path)
      refute content =~ "tools:"
    end
  end

  # ── read_agent/1 ───────────────────────────────────────────

  describe "read_agent/1" do
    test "parses frontmatter and body correctly" do
      config = %{role: "Senior Developer", model: "claude-sonnet-4-6", budget: 150_000, tools: ["Read", "Edit", "Write"], system_prompt: "You are a senior dev."}
      AgentConfig.write_agent("senior", config)

      {:ok, parsed} = AgentConfig.read_agent("senior")

      assert parsed.role == "Senior Developer"
      assert parsed.model == "claude-sonnet-4-6"
      assert parsed.budget == 150_000
      assert parsed.tools == ["Read", "Edit", "Write"]
      assert parsed.system_prompt == "You are a senior dev."
    end

    test "returns error for missing agent" do
      assert {:error, :not_found} = AgentConfig.read_agent("nonexistent_agent")
    end
  end

  # ── read_agent_from_path/1 ─────────────────────────────────

  describe "read_agent_from_path/1" do
    test "works with explicit path", %{tmp_dir: _tmp_dir} do
      config = %{role: "PM", budget: 50_000, tools: ["Read"], system_prompt: "You are a PM."}
      {:ok, path} = AgentConfig.write_agent("pm_explicit", config)

      # Read using the explicit path, not relying on workspace
      {:ok, parsed} = AgentConfig.read_agent_from_path(path)
      assert parsed.role == "PM"
      assert parsed.system_prompt == "You are a PM."
    end

    test "returns error for missing path" do
      bogus = Path.join(System.tmp_dir!(), "bogus_#{System.unique_integer([:positive])}.md")
      assert {:error, :not_found} = AgentConfig.read_agent_from_path(bogus)
    end
  end

  # ── exists?/1 ──────────────────────────────────────────────

  describe "exists?/1" do
    test "returns true when agent file exists" do
      AgentConfig.write_agent("checker", %{role: "Agent"})
      assert AgentConfig.exists?("checker")
    end

    test "returns false when agent file does not exist" do
      refute AgentConfig.exists?("ghost_agent")
    end
  end

  # ── list_agents/0 ──────────────────────────────────────────

  describe "list_agents/0" do
    test "lists .md files" do
      AgentConfig.write_agent("alpha", %{role: "Agent"})
      AgentConfig.write_agent("beta", %{role: "Agent"})

      agents = AgentConfig.list_agents()
      assert "alpha" in agents
      assert "beta" in agents
    end

    test "returns empty list when no agents" do
      # Ensure the directory exists but is empty
      AgentConfig.ensure_dir()
      agents = AgentConfig.list_agents()
      assert agents == []
    end

    test "returns empty list when directory does not exist", %{tmp_dir: tmp_dir} do
      # Point workspace to a completely fresh dir without .shazam/agents
      fresh = Path.join(tmp_dir, "fresh_workspace")
      Application.put_env(:shazam, :workspace, fresh)

      agents = AgentConfig.list_agents()
      assert agents == []
    end
  end

  # ── init_agents/1 ──────────────────────────────────────────

  describe "init_agents/1" do
    test "creates files from agent list" do
      agents = [
        %{name: "init_pm", role: "Project Manager"},
        %{name: "init_dev", role: "Senior Developer"}
      ]

      AgentConfig.init_agents(agents)

      assert AgentConfig.exists?("init_pm")
      assert AgentConfig.exists?("init_dev")
    end
  end

  # ── Parsing edge cases ─────────────────────────────────────

  describe "parsing edge cases" do
    test "parses tools list from frontmatter" do
      config = %{role: "Dev", tools: ["Read", "Edit", "Write", "Bash"], budget: 100_000}
      AgentConfig.write_agent("tooled", config)

      {:ok, parsed} = AgentConfig.read_agent("tooled")
      assert parsed.tools == ["Read", "Edit", "Write", "Bash"]
    end

    test "parses budget as integer" do
      config = %{role: "Dev", budget: 999_999}
      AgentConfig.write_agent("budgeted", config)

      {:ok, parsed} = AgentConfig.read_agent("budgeted")
      assert parsed.budget == 999_999
      assert is_integer(parsed.budget)
    end

    test "handles file without frontmatter", %{tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, ".shazam", "agents"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "bare.md")
      File.write!(path, "Just a plain system prompt with no frontmatter.")

      {:ok, parsed} = AgentConfig.read_agent("bare")
      assert parsed.system_prompt == "Just a plain system prompt with no frontmatter."
      refute Map.has_key?(parsed, :role)
    end

    test "handles budget nil when not present in frontmatter", %{tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, ".shazam", "agents"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "nobudget.md")
      File.write!(path, "---\nrole: Agent\n---\n\nPrompt here.")

      {:ok, parsed} = AgentConfig.read_agent("nobudget")
      assert parsed.budget == nil
    end
  end
end

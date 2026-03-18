defmodule Shazam.AgentPresetsTest do
  use ExUnit.Case, async: true

  alias Shazam.AgentPresets

  @all_preset_ids ["designer", "senior_dev", "junior_dev", "pm", "researcher", "qa", "devops", "writer", "market_analyst", "competitor_analyst"]

  # ── list/0 ───────────────────────────────────────────────

  describe "list/0" do
    test "returns a list of presets" do
      presets = AgentPresets.list()
      assert is_list(presets)
      assert length(presets) > 0
    end

    test "all presets have required fields" do
      for preset <- AgentPresets.list() do
        assert is_binary(preset.id), "preset missing id"
        assert is_binary(preset.label), "preset #{inspect(preset.id)} missing label"
        assert is_binary(preset.icon), "preset #{inspect(preset.id)} missing icon"
        assert is_binary(preset.category), "preset #{inspect(preset.id)} missing category"
        assert is_map(preset.defaults), "preset #{inspect(preset.id)} missing defaults"
      end
    end

    test "all preset defaults have role" do
      for preset <- AgentPresets.list() do
        assert is_binary(preset.defaults.role),
               "preset #{preset.id} defaults missing role"
      end
    end

    test "all preset defaults have budget" do
      for preset <- AgentPresets.list() do
        assert is_integer(preset.defaults.budget),
               "preset #{preset.id} defaults missing budget"
        assert preset.defaults.budget > 0
      end
    end

    test "all preset defaults have tools list" do
      for preset <- AgentPresets.list() do
        assert is_list(preset.defaults.tools),
               "preset #{preset.id} defaults missing tools"
      end
    end

    test "all preset defaults have system_prompt" do
      for preset <- AgentPresets.list() do
        assert is_binary(preset.defaults.system_prompt),
               "preset #{preset.id} defaults missing system_prompt"
        assert String.length(preset.defaults.system_prompt) > 10
      end
    end

    test "presets are sorted by category" do
      presets = AgentPresets.list()
      categories = Enum.map(presets, & &1.category)
      assert categories == Enum.sort(categories)
    end
  end

  # ── get/1 ────────────────────────────────────────────────

  describe "get/1" do
    test "returns preset by ID" do
      for id <- @all_preset_ids do
        preset = AgentPresets.get(id)
        assert preset != nil, "preset #{id} not found"
        assert preset.id == id
      end
    end

    test "returns nil for unknown preset" do
      assert AgentPresets.get("nonexistent") == nil
    end

    test "designer preset has Figma tools" do
      preset = AgentPresets.get("designer")
      assert Enum.any?(preset.defaults.tools, &String.contains?(&1, "figma"))
    end

    test "senior_dev preset has code tools" do
      preset = AgentPresets.get("senior_dev")
      assert "Edit" in preset.defaults.tools
      assert "Write" in preset.defaults.tools
      assert "Bash" in preset.defaults.tools
    end

    test "pm preset has no code tools" do
      preset = AgentPresets.get("pm")
      assert preset.defaults.tools == []
    end

    test "qa preset can write and run tests" do
      preset = AgentPresets.get("qa")
      assert "Bash" in preset.defaults.tools
      assert "Edit" in preset.defaults.tools
    end
  end

  # ── build/2 ──────────────────────────────────────────────

  describe "build/2" do
    test "builds agent config from preset" do
      {:ok, agent} = AgentPresets.build("senior_dev")

      assert is_binary(agent["name"])
      assert agent["role"] == "Senior Developer"
      assert agent["budget"] == 200_000
      assert is_list(agent["tools"])
    end

    test "applies overrides" do
      {:ok, agent} = AgentPresets.build("senior_dev", %{
        "name" => "custom_dev",
        "budget" => 300_000,
        "supervisor" => "pm"
      })

      assert agent["name"] == "custom_dev"
      assert agent["budget"] == 300_000
      assert agent["supervisor"] == "pm"
    end

    test "generates random name when not provided" do
      {:ok, agent1} = AgentPresets.build("junior_dev")
      {:ok, agent2} = AgentPresets.build("junior_dev")

      # Names should contain the preset ID
      assert agent1["name"] =~ "junior_dev"
      assert agent2["name"] =~ "junior_dev"
    end

    test "returns error for unknown preset" do
      assert {:error, :preset_not_found} = AgentPresets.build("nonexistent")
    end

    test "override role" do
      {:ok, agent} = AgentPresets.build("qa", %{"role" => "Custom QA"})
      assert agent["role"] == "Custom QA"
    end

    test "override system_prompt" do
      {:ok, agent} = AgentPresets.build("pm", %{"system_prompt" => "Custom prompt"})
      assert agent["system_prompt"] == "Custom prompt"
    end

    test "override tools" do
      {:ok, agent} = AgentPresets.build("researcher", %{"tools" => ["Read"]})
      assert agent["tools"] == ["Read"]
    end

    test "built agent includes all expected keys" do
      {:ok, agent} = AgentPresets.build("devops")

      expected_keys = ["name", "role", "supervisor", "domain", "budget",
                       "heartbeat_interval", "tools", "skills", "modules",
                       "system_prompt", "model", "fallback_model"]

      for key <- expected_keys do
        assert Map.has_key?(agent, key), "missing key: #{key}"
      end
    end
  end
end

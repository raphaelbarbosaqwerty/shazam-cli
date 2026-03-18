defmodule Shazam.CLI.YamlParserTest do
  use ExUnit.Case, async: true

  alias Shazam.CLI.YamlParser

  @valid_yaml %{
    "company" => %{
      "name" => "TestCo",
      "mission" => "Build great software"
    },
    "agents" => %{
      "pm" => %{
        "role" => "Project Manager",
        "budget" => 50_000
      },
      "dev" => %{
        "role" => "Senior Developer",
        "supervisor" => "pm",
        "budget" => 200_000,
        "tools" => ["Read", "Edit", "Write"],
        "model" => "claude-sonnet-4-6"
      }
    },
    "domains" => %{
      "backend" => %{
        "paths" => ["lib/", "config/"]
      }
    }
  }

  # ── transform/1 — valid input ───────────────────────────

  describe "transform/1 with valid input" do
    test "parses a valid YAML map" do
      assert {:ok, config} = YamlParser.transform(@valid_yaml)

      assert config.name == "TestCo"
      assert config.mission == "Build great software"
      assert is_list(config.agents)
      assert length(config.agents) == 2
    end

    test "builds agent structs with correct fields" do
      {:ok, config} = YamlParser.transform(@valid_yaml)

      dev = Enum.find(config.agents, &(&1.name == "dev"))
      assert dev.role == "Senior Developer"
      assert dev.supervisor == "pm"
      assert dev.budget == 200_000
      assert dev.tools == ["Read", "Edit", "Write"]
      assert dev.model == "claude-sonnet-4-6"
    end

    test "resolves supervisor from supervises field" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{
          "boss" => %{"role" => "Manager", "supervises" => ["worker"]},
          "worker" => %{"role" => "Developer"}
        }
      }

      {:ok, config} = YamlParser.transform(yaml)
      worker = Enum.find(config.agents, &(&1.name == "worker"))
      assert worker.supervisor == "boss"
    end

    test "explicit supervisor takes priority over supervises" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{
          "boss" => %{"role" => "Manager", "supervises" => ["worker"]},
          "actual_boss" => %{"role" => "Director"},
          "worker" => %{"role" => "Developer", "supervisor" => "actual_boss"}
        }
      }

      {:ok, config} = YamlParser.transform(yaml)
      worker = Enum.find(config.agents, &(&1.name == "worker"))
      assert worker.supervisor == "actual_boss"
    end

    test "builds domain config" do
      {:ok, config} = YamlParser.transform(@valid_yaml)

      assert Map.has_key?(config.domain_config, "backend")
      assert config.domain_config["backend"]["allowed_paths"] == ["lib/", "config/"]
    end

    test "builds modules from domain paths" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{
          "dev" => %{"role" => "Developer", "domain" => "backend"}
        },
        "domains" => %{
          "backend" => %{"paths" => ["lib/api/"]}
        }
      }

      {:ok, config} = YamlParser.transform(yaml)
      dev = Enum.find(config.agents, &(&1.name == "dev"))
      assert dev.modules == [%{"name" => "backend", "paths" => ["lib/api/"]}]
    end

    test "workspace is captured from company section" do
      yaml = put_in(@valid_yaml, ["company", "workspace"], "/my/project")
      {:ok, config} = YamlParser.transform(yaml)

      assert config.workspace == "/my/project"
    end
  end

  # ── transform/1 — tech_stack ────────────────────────────

  describe "transform/1 tech_stack handling" do
    test "parses tech_stack section" do
      yaml = Map.put(@valid_yaml, "tech_stack", %{"language" => "Elixir", "framework" => "Phoenix"})
      {:ok, config} = YamlParser.transform(yaml)

      assert config.tech_stack == %{"language" => "Elixir", "framework" => "Phoenix"}
    end

    test "tech_stack is nil when not present" do
      {:ok, config} = YamlParser.transform(@valid_yaml)
      assert config.tech_stack == nil
    end

    test "non-map tech_stack is treated as nil" do
      yaml = Map.put(@valid_yaml, "tech_stack", "not a map")
      {:ok, config} = YamlParser.transform(yaml)
      assert config.tech_stack == nil
    end
  end

  # ── transform/1 — config section ───────────────────────

  describe "transform/1 ralph_config" do
    test "parses config section" do
      yaml = Map.put(@valid_yaml, "config", %{
        "auto_approve" => true,
        "auto_retry" => true,
        "max_concurrent" => 8,
        "max_retries" => 3,
        "poll_interval" => 10_000,
        "module_lock" => false,
        "peer_reassign" => false
      })

      {:ok, config} = YamlParser.transform(yaml)
      rc = config.ralph_config

      assert rc.auto_approve == true
      assert rc.auto_retry == true
      assert rc.max_concurrent == 8
      assert rc.max_retries == 3
      assert rc.poll_interval == 10_000
      assert rc.module_lock == false
      assert rc.peer_reassign == false
    end

    test "provides defaults when config section is missing" do
      {:ok, config} = YamlParser.transform(@valid_yaml)
      rc = config.ralph_config

      assert rc.auto_approve == false
      assert rc.auto_retry == false
      assert rc.max_concurrent == 4
      assert rc.max_retries == 2
      assert rc.module_lock == true
      assert rc.peer_reassign == true
    end
  end

  # ── transform/1 — validation errors ─────────────────────

  describe "transform/1 validation errors" do
    test "rejects non-map input" do
      assert {:error, _} = YamlParser.transform("not a map")
    end

    test "rejects missing company name" do
      yaml = put_in(@valid_yaml, ["company", "name"], "")
      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "company.name"
    end

    test "rejects missing company mission" do
      yaml = put_in(@valid_yaml, ["company", "mission"], "")
      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "company.mission"
    end

    test "rejects empty agents section" do
      yaml = Map.put(@valid_yaml, "agents", %{})
      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "at least one agent"
    end

    test "rejects agent without role" do
      yaml = put_in(@valid_yaml, ["agents"], %{"bad" => %{}})
      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "role"
    end

    test "rejects agent referencing unknown supervisor" do
      yaml = put_in(@valid_yaml, ["agents"], %{
        "dev" => %{"role" => "Dev", "supervisor" => "ghost"}
      })

      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "ghost"
    end

    test "rejects nil company section" do
      yaml = Map.put(@valid_yaml, "company", nil)
      assert {:error, msg} = YamlParser.transform(yaml)
      assert msg =~ "company.name"
    end
  end

  # ── Default tools ───────────────────────────────────────

  describe "default tools by role" do
    test "developer roles get dev tools" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{"dev" => %{"role" => "Senior Developer"}}
      }

      {:ok, config} = YamlParser.transform(yaml)
      dev = Enum.find(config.agents, &(&1.name == "dev"))
      assert "Edit" in dev.tools
      assert "Write" in dev.tools
      assert "Bash" in dev.tools
    end

    test "manager roles get manager tools" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{"pm" => %{"role" => "Project Manager"}}
      }

      {:ok, config} = YamlParser.transform(yaml)
      pm = Enum.find(config.agents, &(&1.name == "pm"))
      assert "WebSearch" in pm.tools
    end

    test "QA roles get QA tools" do
      yaml = %{
        "company" => %{"name" => "Co", "mission" => "Go"},
        "agents" => %{"qa" => %{"role" => "QA Tester"}}
      }

      {:ok, config} = YamlParser.transform(yaml)
      qa = Enum.find(config.agents, &(&1.name == "qa"))
      assert "Bash" in qa.tools
    end
  end

  # ── to_yaml/1 round-trip ────────────────────────────────

  describe "to_yaml/1" do
    test "generates valid YAML string" do
      config = %{
        name: "TestCo",
        mission: "Build things",
        agents: [
          %{name: "pm", role: "Project Manager", budget: 50_000, tools: []},
          %{name: "dev", role: "Developer", supervisor: "pm", budget: 100_000, tools: ["Read", "Edit"]}
        ],
        domains: %{
          "backend" => %{"paths" => ["lib/"], "description" => "Backend code"}
        },
        ralph_config: %{
          auto_approve: false,
          auto_retry: true,
          max_concurrent: 4,
          max_retries: 2,
          poll_interval: 5000,
          module_lock: true,
          peer_reassign: true
        },
        tech_stack: %{
          "language" => "Elixir",
          "framework" => "Phoenix"
        }
      }

      yaml = YamlParser.to_yaml(config)
      assert is_binary(yaml)
      assert yaml =~ "company:"
      assert yaml =~ "TestCo"
      assert yaml =~ "Build things"
      assert yaml =~ "agents:"
      assert yaml =~ "pm"
      assert yaml =~ "dev"
      assert yaml =~ "domains:"
      assert yaml =~ "backend"
      assert yaml =~ "tech_stack:"
      assert yaml =~ "Elixir"
    end

    test "handles empty domains" do
      config = %{name: "Co", mission: "Go", agents: [], domains: %{}}
      yaml = YamlParser.to_yaml(config)
      refute yaml =~ "domains:"
    end

    test "handles nil ralph_config" do
      config = %{name: "Co", mission: "Go", agents: [], domains: %{}}
      yaml = YamlParser.to_yaml(config)
      assert yaml =~ "config:"
    end

    test "handles empty tech_stack" do
      config = %{name: "Co", mission: "Go", agents: [], domains: %{}, tech_stack: %{}}
      yaml = YamlParser.to_yaml(config)
      # Should output commented-out tech_stack
      assert yaml =~ "tech_stack"
    end

    test "quotes strings with special characters" do
      config = %{
        name: "My: Company",
        mission: "Do #great things",
        agents: [],
        domains: %{}
      }

      yaml = YamlParser.to_yaml(config)
      # Special chars should be quoted
      assert yaml =~ "\""
    end
  end

  # ── parse/1 — file not found ────────────────────────────

  describe "parse/1" do
    test "returns error for non-existent file" do
      assert {:error, msg} = YamlParser.parse("/tmp/nonexistent_shazam_test_#{System.unique_integer()}.yaml")
      assert is_binary(msg)
    end

    test "parses a valid YAML file" do
      path = "/tmp/shazam_test_#{System.unique_integer([:positive])}.yaml"

      content = """
      company:
        name: FileCo
        mission: Test parsing
      agents:
        dev:
          role: Developer
      """

      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, config} = YamlParser.parse(path)
      assert config.name == "FileCo"
    end
  end
end

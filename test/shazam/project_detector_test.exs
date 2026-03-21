defmodule Shazam.ProjectDetectorTest do
  use ExUnit.Case, async: true

  alias Shazam.ProjectDetector

  @moduletag :project_detector

  describe "detect/1" do
    test "detects current project directory as Elixir" do
      result = ProjectDetector.detect(File.cwd!())

      assert is_map(result)
      assert result.language =~ "Elixir"
      assert result.testing != nil
      assert is_list(result.domains)
      assert is_list(result.suggested_agents)
      assert is_map(result.tech_stack)
    end

    test "returns base structure for empty temp directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_pd_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      result = ProjectDetector.detect(tmp_dir)

      assert is_map(result)
      assert result.language == nil
      assert result.framework == nil
      assert result.database == nil
      assert result.monorepo == false
      assert result.domains == []
      # Should suggest at least a PM and a generic dev
      assert length(result.suggested_agents) >= 2

      File.rm_rf!(tmp_dir)
    end

    test "detects Node.js project with package.json" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_pd_node_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "package.json"), Jason.encode!(%{
        "name" => "test-app",
        "dependencies" => %{
          "react" => "^18.0.0",
          "typescript" => "^5.0.0"
        },
        "devDependencies" => %{
          "vitest" => "^1.0.0",
          "tailwindcss" => "^3.0.0"
        }
      }))

      result = ProjectDetector.detect(tmp_dir)

      assert result.language in ["JavaScript", "TypeScript"]
      assert result.framework == "React"
      assert result.styling == "Tailwind CSS"
      assert result.testing == "Vitest"

      File.rm_rf!(tmp_dir)
    end

    test "detects domains based on directory structure" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_pd_domains_#{System.unique_integer([:positive])}")

      # Create domain directories
      File.mkdir_p!(Path.join(tmp_dir, "app"))
      File.mkdir_p!(Path.join(tmp_dir, "components"))
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "test"))

      result = ProjectDetector.detect(tmp_dir)

      domain_names = Enum.map(result.domains, & &1.name)
      assert "frontend" in domain_names
      assert "backend" in domain_names
      assert "testing" in domain_names

      File.rm_rf!(tmp_dir)
    end

    test "suggests agents based on detected domains" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_pd_agents_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "app"))
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "test"))

      # Add mix.exs for testing detection
      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule TestApp.MixProject do
        use Mix.Project
        def project do
          [app: :test_app]
        end
      end
      """)

      result = ProjectDetector.detect(tmp_dir)

      agent_names = Enum.map(result.suggested_agents, & &1.name)
      assert "pm" in agent_names

      File.rm_rf!(tmp_dir)
    end
  end

  describe "detect_domains/1" do
    test "returns empty list for directory with no recognized structure" do
      tmp_dir = Path.join(System.tmp_dir!(), "shazam_pd_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      domains = ProjectDetector.detect_domains(tmp_dir)
      assert domains == []

      File.rm_rf!(tmp_dir)
    end
  end

  describe "summary/1" do
    test "returns human-readable string" do
      result = ProjectDetector.detect(File.cwd!())
      summary = ProjectDetector.summary(result)

      assert is_binary(summary)
      assert summary =~ "Language"
    end
  end
end

defmodule Shazam.HierarchyFullTest do
  use ExUnit.Case, async: true

  alias Shazam.Hierarchy
  import Shazam.Test.Factory

  @agents [
    %{name: "ceo", role: "CEO", supervisor: nil},
    %{name: "vp_eng", role: "VP Engineering", supervisor: "ceo"},
    %{name: "vp_sales", role: "VP Sales", supervisor: "ceo"},
    %{name: "pm", role: "Project Manager", supervisor: "vp_eng"},
    %{name: "dev1", role: "Senior Developer", supervisor: "pm"},
    %{name: "dev2", role: "Junior Developer", supervisor: "pm"},
    %{name: "qa", role: "QA Engineer", supervisor: "pm"},
    %{name: "sales_rep", role: "Sales Representative", supervisor: "vp_sales"}
  ]

  # ── find_supervisor ──────────────────────────────────────

  describe "find_supervisor/2" do
    test "returns the direct supervisor" do
      sup = Hierarchy.find_supervisor(@agents, "dev1")
      assert sup.name == "pm"
    end

    test "returns nil for the root agent" do
      assert Hierarchy.find_supervisor(@agents, "ceo") == nil
    end

    test "returns nil for unknown agent" do
      assert Hierarchy.find_supervisor(@agents, "ghost") == nil
    end

    test "returns correct supervisor in multi-level hierarchy" do
      sup = Hierarchy.find_supervisor(@agents, "pm")
      assert sup.name == "vp_eng"
    end
  end

  # ── find_subordinates ────────────────────────────────────

  describe "find_subordinates/2" do
    test "returns direct subordinates" do
      subs = Hierarchy.find_subordinates(@agents, "pm")
      names = Enum.map(subs, & &1.name) |> Enum.sort()

      assert names == ["dev1", "dev2", "qa"]
    end

    test "returns empty list for leaf agents" do
      assert Hierarchy.find_subordinates(@agents, "dev1") == []
    end

    test "returns multiple branches at top level" do
      subs = Hierarchy.find_subordinates(@agents, "ceo")
      names = Enum.map(subs, & &1.name) |> Enum.sort()

      assert names == ["vp_eng", "vp_sales"]
    end

    test "returns empty for unknown agent" do
      assert Hierarchy.find_subordinates(@agents, "ghost") == []
    end
  end

  # ── is_superior? ─────────────────────────────────────────

  describe "is_superior?/3" do
    test "detects direct superiority" do
      assert Hierarchy.is_superior?(@agents, "pm", "dev1")
    end

    test "detects indirect superiority" do
      assert Hierarchy.is_superior?(@agents, "ceo", "dev2")
    end

    test "returns false for peers" do
      refute Hierarchy.is_superior?(@agents, "dev1", "dev2")
    end

    test "returns false for reverse direction" do
      refute Hierarchy.is_superior?(@agents, "dev1", "pm")
    end

    test "returns false for agents in different branches" do
      refute Hierarchy.is_superior?(@agents, "vp_sales", "dev1")
    end

    test "returns false for self" do
      refute Hierarchy.is_superior?(@agents, "pm", "pm")
    end

    test "returns false for unknown agent" do
      refute Hierarchy.is_superior?(@agents, "ghost", "dev1")
    end
  end

  # ── chain_of_command ─────────────────────────────────────

  describe "chain_of_command/2" do
    test "returns full chain to the top" do
      chain = Hierarchy.chain_of_command(@agents, "dev1")
      names = Enum.map(chain, & &1.name)

      assert names == ["pm", "vp_eng", "ceo"]
    end

    test "returns empty chain for root" do
      assert Hierarchy.chain_of_command(@agents, "ceo") == []
    end

    test "returns single-element chain for direct report of root" do
      chain = Hierarchy.chain_of_command(@agents, "vp_eng")
      names = Enum.map(chain, & &1.name)

      assert names == ["ceo"]
    end

    test "deep chain with 4 levels" do
      chain = Hierarchy.chain_of_command(@agents, "qa")
      names = Enum.map(chain, & &1.name)

      assert names == ["pm", "vp_eng", "ceo"]
    end
  end

  # ── validate_no_cycles ───────────────────────────────────

  describe "validate_no_cycles/1" do
    test "valid hierarchy returns :ok" do
      assert :ok = Hierarchy.validate_no_cycles(@agents)
    end

    test "detects a simple 2-node cycle" do
      agents = [
        %{name: "a", role: "A", supervisor: "b"},
        %{name: "b", role: "B", supervisor: "a"}
      ]

      assert {:error, {:cycle_detected, nodes}} = Hierarchy.validate_no_cycles(agents)
      assert "a" in nodes
      assert "b" in nodes
    end

    test "detects a 3-node cycle" do
      agents = [
        %{name: "a", role: "A", supervisor: "c"},
        %{name: "b", role: "B", supervisor: "a"},
        %{name: "c", role: "C", supervisor: "b"}
      ]

      assert {:error, {:cycle_detected, _nodes}} = Hierarchy.validate_no_cycles(agents)
    end

    test "valid hierarchy with single node" do
      agents = [%{name: "solo", role: "Solo", supervisor: nil}]
      assert :ok = Hierarchy.validate_no_cycles(agents)
    end

    test "self-referencing supervisor is a cycle" do
      agents = [%{name: "loop", role: "Loop", supervisor: "loop"}]
      assert {:error, {:cycle_detected, ["loop"]}} = Hierarchy.validate_no_cycles(agents)
    end

    test "handles agents referencing non-existent supervisors gracefully" do
      agents = [
        %{name: "orphan", role: "Orphan", supervisor: "ghost"},
        %{name: "root", role: "Root", supervisor: nil}
      ]

      assert :ok = Hierarchy.validate_no_cycles(agents)
    end

    test "mixed valid and cycled nodes" do
      agents = [
        %{name: "root", role: "Root", supervisor: nil},
        %{name: "good", role: "Good", supervisor: "root"},
        %{name: "cycle_a", role: "A", supervisor: "cycle_b"},
        %{name: "cycle_b", role: "B", supervisor: "cycle_a"}
      ]

      assert {:error, {:cycle_detected, nodes}} = Hierarchy.validate_no_cycles(agents)
      assert "cycle_a" in nodes
      assert "cycle_b" in nodes
      # The valid nodes should not be in cycle list
      refute "root" in nodes
      refute "good" in nodes
    end

    test "deep chain without cycles is valid" do
      agents = Enum.map(0..9, fn i ->
        %{
          name: "level_#{i}",
          role: "Level #{i}",
          supervisor: if(i > 0, do: "level_#{i - 1}", else: nil)
        }
      end)

      assert :ok = Hierarchy.validate_no_cycles(agents)
    end
  end

  # ── best_subordinate_for ─────────────────────────────────

  describe "best_subordinate_for/3" do
    test "matches based on role keywords" do
      best = Hierarchy.best_subordinate_for(@agents, "pm", "We need a Senior Developer to refactor the code")
      assert best.name == "dev1"
    end

    test "returns nil when no subordinates exist" do
      assert Hierarchy.best_subordinate_for(@agents, "dev1", "any task") == nil
    end

    test "returns a subordinate even with zero score" do
      # The task description has no matching words but there are subordinates
      result = Hierarchy.best_subordinate_for(@agents, "pm", "xyz unrelated words")
      assert result != nil
      assert result.name in ["dev1", "dev2", "qa"]
    end
  end

  # ── Orphan handling ──────────────────────────────────────

  describe "orphan handling" do
    test "orphans have no supervisor found" do
      agents_with_orphan = [
        %{name: "root", role: "Root", supervisor: nil},
        %{name: "orphan", role: "Dev", supervisor: "nonexistent"}
      ]

      assert Hierarchy.find_supervisor(agents_with_orphan, "orphan") == nil
    end

    test "orphans do not appear as subordinates of anyone" do
      agents_with_orphan = [
        %{name: "root", role: "Root", supervisor: nil},
        %{name: "orphan", role: "Dev", supervisor: "nonexistent"}
      ]

      subs = Hierarchy.find_subordinates(agents_with_orphan, "root")
      refute Enum.any?(subs, &(&1.name == "orphan"))
    end

    test "chain_of_command for orphan is empty" do
      agents_with_orphan = [
        %{name: "orphan", role: "Dev", supervisor: "nonexistent"}
      ]

      assert Hierarchy.chain_of_command(agents_with_orphan, "orphan") == []
    end
  end
end

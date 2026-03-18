defmodule Shazam.TaskSchedulerTest do
  use ExUnit.Case, async: true

  alias Shazam.TaskScheduler

  # ── task_blocked? ────────────────────────────────────────

  describe "task_blocked?/1" do
    test "nil dependency is not blocked" do
      refute TaskScheduler.task_blocked?(%{depends_on: nil})
    end

    test "empty string dependency is not blocked" do
      refute TaskScheduler.task_blocked?(%{depends_on: ""})
    end

    test "empty list dependency is not blocked" do
      refute TaskScheduler.task_blocked?(%{depends_on: []})
    end

    test "map without depends_on is not blocked" do
      refute TaskScheduler.task_blocked?(%{})
    end

    test "map with unrecognized depends_on type is not blocked" do
      refute TaskScheduler.task_blocked?(%{depends_on: 42})
    end
  end

  # ── extract_module_paths ─────────────────────────────────

  describe "extract_module_paths/1" do
    test "returns empty list for nil" do
      assert TaskScheduler.extract_module_paths(nil) == []
    end

    test "extracts string-keyed paths" do
      modules = [%{"path" => "lib/api/"}, %{"path" => "lib/core/"}]
      assert TaskScheduler.extract_module_paths(modules) == ["lib/api/", "lib/core/"]
    end

    test "extracts atom-keyed paths" do
      modules = [%{path: "lib/api/"}, %{path: "lib/core/"}]
      assert TaskScheduler.extract_module_paths(modules) == ["lib/api/", "lib/core/"]
    end

    test "filters out nil paths" do
      modules = [%{"path" => "lib/"}, %{"name" => "no_path"}]
      assert TaskScheduler.extract_module_paths(modules) == ["lib/"]
    end

    test "handles empty list" do
      assert TaskScheduler.extract_module_paths([]) == []
    end

    test "handles mixed key types" do
      modules = [%{"path" => "a/"}, %{path: "b/"}]
      assert TaskScheduler.extract_module_paths(modules) == ["a/", "b/"]
    end
  end

  # ── collect_ancestors ────────────────────────────────────

  describe "collect_ancestors/3" do
    test "collects all ancestors up the chain" do
      agents = [
        %{name: "ceo", role: "CEO", supervisor: nil},
        %{name: "vp", role: "VP", supervisor: "ceo"},
        %{name: "dev", role: "Dev", supervisor: "vp"}
      ]

      result = TaskScheduler.collect_ancestors(agents, "dev", MapSet.new(["dev"]))
      assert MapSet.member?(result, "dev")
      assert MapSet.member?(result, "vp")
      assert MapSet.member?(result, "ceo")
    end

    test "handles nil agent name" do
      result = TaskScheduler.collect_ancestors([], nil, MapSet.new())
      assert result == MapSet.new()
    end

    test "does not loop on already-visited nodes" do
      agents = [
        %{name: "a", role: "A", supervisor: "b"},
        %{name: "b", role: "B", supervisor: "a"}
      ]

      # Starting with "a" already in acc, walk to "b" but "b" points back to "a" which is already visited
      result = TaskScheduler.collect_ancestors(agents, "a", MapSet.new(["a"]))
      assert MapSet.member?(result, "a")
      assert MapSet.member?(result, "b")
    end
  end

  # ── collect_descendants ──────────────────────────────────

  describe "collect_descendants/3" do
    test "collects all descendants down the tree" do
      agents = [
        %{name: "root", role: "Root", supervisor: nil},
        %{name: "mid", role: "Mid", supervisor: "root"},
        %{name: "leaf1", role: "Leaf1", supervisor: "mid"},
        %{name: "leaf2", role: "Leaf2", supervisor: "mid"}
      ]

      result = TaskScheduler.collect_descendants(agents, "root", MapSet.new())
      assert MapSet.member?(result, "mid")
      assert MapSet.member?(result, "leaf1")
      assert MapSet.member?(result, "leaf2")
    end

    test "returns empty for leaf agent" do
      agents = [
        %{name: "root", role: "Root", supervisor: nil},
        %{name: "leaf", role: "Leaf", supervisor: "root"}
      ]

      result = TaskScheduler.collect_descendants(agents, "leaf", MapSet.new())
      assert result == MapSet.new()
    end

    test "handles already-visited nodes (cycle protection)" do
      agents = [
        %{name: "a", role: "A", supervisor: nil},
        %{name: "b", role: "B", supervisor: "a"}
      ]

      # If "b" is already in acc, it should not be re-processed
      result = TaskScheduler.collect_descendants(agents, "a", MapSet.new(["b"]))
      assert MapSet.member?(result, "b")
    end
  end

  # ── locked_module_paths ──────────────────────────────────

  describe "locked_module_paths/2" do
    test "returns empty map when no running tasks" do
      assert TaskScheduler.locked_module_paths(%{}, "any_company") == %{}
    end
  end

  # ── pick_tasks ───────────────────────────────────────────

  describe "pick_tasks/5" do
    test "returns state unchanged when no candidates" do
      state = %{running: %{}, peer_reassign: false, module_lock: false, company_name: "co"}
      result = TaskScheduler.pick_tasks([], state, %{}, 5, fn s, _t -> s end)
      assert result == state
    end

    test "returns state unchanged when zero slots" do
      state = %{running: %{}, peer_reassign: false, module_lock: false, company_name: "co"}
      task = %{id: "task_1", assigned_to: "agent", status: :pending}
      result = TaskScheduler.pick_tasks([task], state, %{}, 0, fn s, _t -> s end)
      assert result == state
    end

    test "executes task when agent is not busy" do
      state = %{running: %{}, peer_reassign: false, module_lock: false, company_name: "co"}
      task = %{id: "task_1", assigned_to: "agent_a", status: :pending}

      execute_fn = fn s, t ->
        Map.update!(s, :running, &Map.put(&1, t.id, %{agent_name: t.assigned_to}))
      end

      result = TaskScheduler.pick_tasks([task], state, %{}, 5, execute_fn)
      assert Map.has_key?(result.running, "task_1")
    end

    test "skips task when agent is busy and peer_reassign is disabled" do
      state = %{
        running: %{"task_0" => %{agent_name: "busy_agent"}},
        peer_reassign: false,
        module_lock: false,
        company_name: "co"
      }
      task = %{id: "task_1", assigned_to: "busy_agent", status: :pending}

      result = TaskScheduler.pick_tasks([task], state, %{}, 5, fn s, _t -> s end)
      refute Map.has_key?(result.running, "task_1")
    end
  end
end

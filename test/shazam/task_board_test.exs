defmodule Shazam.TaskBoardFullTest do
  use ExUnit.Case, async: false

  alias Shazam.TaskBoard
  import Shazam.Test.Factory

  setup do
    # Ensure EventBus is running (TaskBoard broadcasts to it)
    ensure_started(Shazam.API.EventBus)
    ensure_started(Shazam.TaskBoard)
    # Clear all tasks before each test
    TaskBoard.clear_all()
    :ok
  end

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  # ── Create ────────────────────────────────────────────────

  describe "create/1" do
    test "creates a task with pending status" do
      {:ok, task} = TaskBoard.create(build_task(title: "My Task"))

      assert task.id =~ "task_"
      assert task.title == "My Task"
      assert task.status == :pending
    end

    test "assigns default title when missing" do
      {:ok, task} = TaskBoard.create(%{})
      assert task.title == "Untitled"
    end

    test "preserves all provided attributes" do
      attrs = build_task(
        title: "Full Task",
        description: "A description",
        assigned_to: "agent_a",
        created_by: "boss",
        parent_task_id: "task_0",
        depends_on: "task_0",
        company: "acme"
      )

      {:ok, task} = TaskBoard.create(attrs)

      assert task.description == "A description"
      assert task.assigned_to == "agent_a"
      assert task.created_by == "boss"
      assert task.parent_task_id == "task_0"
      assert task.depends_on == "task_0"
      assert task.company == "acme"
    end

    test "sets timestamps on creation" do
      {:ok, task} = TaskBoard.create(build_task())
      assert %DateTime{} = task.created_at
      assert %DateTime{} = task.updated_at
    end

    test "generates sequential IDs" do
      {:ok, t1} = TaskBoard.create(build_task())
      {:ok, t2} = TaskBoard.create(build_task())

      [_, n1] = Regex.run(~r/task_(\d+)/, t1.id)
      [_, n2] = Regex.run(~r/task_(\d+)/, t2.id)
      assert String.to_integer(n2) == String.to_integer(n1) + 1
    end

    test "initializes retry fields" do
      {:ok, task} = TaskBoard.create(build_task())
      assert task.retry_count == 0
      assert task.max_retries == 2
      assert task.last_error == nil
    end

    test "accepts custom retry settings" do
      {:ok, task} = TaskBoard.create(build_task() |> Map.put(:max_retries, 5) |> Map.put(:retry_count, 1))
      assert task.max_retries == 5
      assert task.retry_count == 1
    end
  end

  # ── Get ───────────────────────────────────────────────────

  describe "get/1" do
    test "returns task by ID" do
      {:ok, task} = TaskBoard.create(build_task(title: "Findable"))
      assert {:ok, found} = TaskBoard.get(task.id)
      assert found.title == "Findable"
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = TaskBoard.get("task_nonexistent")
    end
  end

  # ── Checkout ──────────────────────────────────────────────

  describe "checkout/2" do
    test "transitions pending -> in_progress" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, checked} = TaskBoard.checkout(task.id, "worker")

      assert checked.status == :in_progress
      assert checked.assigned_to == "worker"
    end

    test "fails on already checked-out task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent1")

      assert {:error, {:already_taken, :in_progress}} = TaskBoard.checkout(task.id, "agent2")
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.checkout("task_nope", "agent")
    end

    test "fails on completed task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, _} = TaskBoard.complete(task.id, "done")

      assert {:error, {:already_taken, :completed}} = TaskBoard.checkout(task.id, "agent2")
    end

    test "updates the updated_at timestamp" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, checked} = TaskBoard.checkout(task.id, "agent")

      assert DateTime.compare(checked.updated_at, task.created_at) in [:gt, :eq]
    end
  end

  # ── Complete ──────────────────────────────────────────────

  describe "complete/2" do
    test "transitions in_progress -> completed with result" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, completed} = TaskBoard.complete(task.id, "Result data")

      assert completed.status == :completed
      assert completed.result == "Result data"
    end

    test "fails on pending task" do
      {:ok, task} = TaskBoard.create(build_task())
      assert {:error, :not_in_progress} = TaskBoard.complete(task.id, "result")
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.complete("task_nope", "result")
    end
  end

  # ── Fail ──────────────────────────────────────────────────

  describe "fail/2" do
    test "transitions any task to failed" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, failed} = TaskBoard.fail(task.id, "timeout")

      assert failed.status == :failed
      assert failed.result == {:error, "timeout"}
    end

    test "can fail a pending task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, failed} = TaskBoard.fail(task.id, "cancelled")

      assert failed.status == :failed
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.fail("task_nope", "reason")
    end
  end

  # ── Pause ─────────────────────────────────────────────────

  describe "pause/1" do
    test "pauses a pending task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, paused} = TaskBoard.pause(task.id)

      assert paused.status == :paused
    end

    test "pauses an in_progress task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, paused} = TaskBoard.pause(task.id)

      assert paused.status == :paused
    end

    test "cannot pause a completed task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, _} = TaskBoard.complete(task.id, "done")

      assert {:error, {:not_pausable, :completed}} = TaskBoard.pause(task.id)
    end

    test "cannot pause a failed task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.fail(task.id, "err")

      assert {:error, {:not_pausable, :failed}} = TaskBoard.pause(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.pause("task_nope")
    end
  end

  # ── Resume ────────────────────────────────────────────────

  describe "resume_task/1" do
    test "resumes a paused task to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.pause(task.id)
      {:ok, resumed} = TaskBoard.resume_task(task.id)

      assert resumed.status == :pending
    end

    test "cannot resume a non-paused task" do
      {:ok, task} = TaskBoard.create(build_task())

      assert {:error, {:not_paused, :pending}} = TaskBoard.resume_task(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.resume_task("task_nope")
    end
  end

  # ── Retry ─────────────────────────────────────────────────

  describe "retry/1" do
    test "retries a failed task back to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.fail(task.id, "err")
      {:ok, retried} = TaskBoard.retry(task.id)

      assert retried.status == :pending
      assert retried.result == nil
    end

    test "retries a completed task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, _} = TaskBoard.complete(task.id, "done")
      {:ok, retried} = TaskBoard.retry(task.id)

      assert retried.status == :pending
    end

    test "retries a rejected task" do
      {:ok, task} = TaskBoard.create_awaiting(build_task())
      {:ok, _} = TaskBoard.reject(task.id, "no")
      {:ok, retried} = TaskBoard.retry(task.id)

      assert retried.status == :pending
    end

    test "cannot retry a pending task" do
      {:ok, task} = TaskBoard.create(build_task())

      assert {:error, {:not_retryable, :pending}} = TaskBoard.retry(task.id)
    end

    test "cannot retry an in_progress task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")

      assert {:error, {:not_retryable, :in_progress}} = TaskBoard.retry(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.retry("task_nope")
    end
  end

  # ── Increment Retry ──────────────────────────────────────

  describe "increment_retry/2" do
    test "increments retry count and resets to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, _} = TaskBoard.fail(task.id, "err")
      {:ok, retried} = TaskBoard.increment_retry(task.id, "timeout error")

      assert retried.retry_count == 1
      assert retried.last_error == "timeout error"
      assert retried.status == :pending
      assert retried.result == nil
    end

    test "increments multiple times" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.increment_retry(task.id, "err1")
      {:ok, r2} = TaskBoard.increment_retry(task.id, "err2")

      assert r2.retry_count == 2
      assert r2.last_error == "err2"
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.increment_retry("task_nope", "err")
    end
  end

  # ── Delete / Restore / Purge ─────────────────────────────

  describe "delete/1" do
    test "soft-deletes a task" do
      {:ok, task} = TaskBoard.create(build_task())
      assert :ok = TaskBoard.delete(task.id)

      {:ok, deleted} = TaskBoard.get(task.id)
      assert deleted.status == :deleted
    end

    test "soft-deleted tasks are hidden from list by default" do
      {:ok, task} = TaskBoard.create(build_task(title: "DeleteMe"))
      TaskBoard.delete(task.id)

      tasks = TaskBoard.list(%{})
      refute Enum.any?(tasks, &(&1.id == task.id))
    end

    test "soft-deleted tasks visible with include_deleted flag" do
      {:ok, task} = TaskBoard.create(build_task(title: "DeleteMe"))
      TaskBoard.delete(task.id)

      tasks = TaskBoard.list(%{include_deleted: true})
      assert Enum.any?(tasks, &(&1.id == task.id))
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.delete("task_nope")
    end
  end

  describe "restore/1" do
    test "restores a deleted task to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      TaskBoard.delete(task.id)
      {:ok, restored} = TaskBoard.restore(task.id)

      assert restored.status == :pending
    end

    test "cannot restore a non-deleted task" do
      {:ok, task} = TaskBoard.create(build_task())

      assert {:error, {:not_deleted, :pending}} = TaskBoard.restore(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.restore("task_nope")
    end
  end

  describe "purge/1" do
    test "permanently removes a task" do
      {:ok, task} = TaskBoard.create(build_task())
      assert :ok = TaskBoard.purge(task.id)
      assert {:error, :not_found} = TaskBoard.get(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.purge("task_nope")
    end
  end

  # ── Reassign ──────────────────────────────────────────────

  describe "reassign/2" do
    test "reassigns a pending task" do
      {:ok, task} = TaskBoard.create(build_task(assigned_to: "agent_a"))
      {:ok, reassigned} = TaskBoard.reassign(task.id, "agent_b")

      assert reassigned.assigned_to == "agent_b"
      assert reassigned.status == :pending
    end

    test "reassigning a failed task resets to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.fail(task.id, "err")
      {:ok, reassigned} = TaskBoard.reassign(task.id, "new_agent")

      assert reassigned.status == :pending
      assert reassigned.assigned_to == "new_agent"
    end

    test "reassigning a completed task resets to pending" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")
      {:ok, _} = TaskBoard.complete(task.id, "done")
      {:ok, reassigned} = TaskBoard.reassign(task.id, "new_agent")

      assert reassigned.status == :pending
      assert reassigned.result == nil
    end

    test "cannot reassign an in_progress task" do
      {:ok, task} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(task.id, "agent")

      assert {:error, {:cannot_reassign, :in_progress}} = TaskBoard.reassign(task.id, "other")
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.reassign("task_nope", "agent")
    end
  end

  # ── Clear All ─────────────────────────────────────────────

  describe "clear_all/0" do
    test "removes all tasks and returns count" do
      TaskBoard.create(build_task())
      TaskBoard.create(build_task())
      TaskBoard.create(build_task())

      {:ok, count} = TaskBoard.clear_all()
      assert count >= 3

      tasks = TaskBoard.list(%{})
      assert tasks == []
    end
  end

  # ── Awaiting Approval Flow ────────────────────────────────

  describe "create_awaiting/1" do
    test "creates a task with awaiting_approval status" do
      {:ok, task} = TaskBoard.create_awaiting(build_task(title: "Needs Approval"))

      assert task.status == :awaiting_approval
    end
  end

  describe "approve/1" do
    test "approves an awaiting task to pending" do
      {:ok, task} = TaskBoard.create_awaiting(build_task())
      {:ok, approved} = TaskBoard.approve(task.id)

      assert approved.status == :pending
    end

    test "cannot approve a non-awaiting task" do
      {:ok, task} = TaskBoard.create(build_task())

      assert {:error, {:not_awaiting_approval, :pending}} = TaskBoard.approve(task.id)
    end

    test "fails on non-existent task" do
      assert {:error, :not_found} = TaskBoard.approve("task_nope")
    end
  end

  describe "reject/2" do
    test "rejects an awaiting task" do
      {:ok, task} = TaskBoard.create_awaiting(build_task())
      {:ok, rejected} = TaskBoard.reject(task.id, "Not good enough")

      assert rejected.status == :rejected
      assert rejected.result == "Not good enough"
    end

    test "rejects with default reason" do
      {:ok, task} = TaskBoard.create_awaiting(build_task())
      {:ok, rejected} = TaskBoard.reject(task.id)

      assert rejected.status == :rejected
      assert rejected.result == "Rejected by user"
    end

    test "cannot reject a non-awaiting task" do
      {:ok, task} = TaskBoard.create(build_task())

      assert {:error, {:not_awaiting_approval, :pending}} = TaskBoard.reject(task.id)
    end
  end

  # ── List / Filters ───────────────────────────────────────

  describe "list/1" do
    test "returns all non-deleted tasks" do
      {:ok, _} = TaskBoard.create(build_task(title: "T1"))
      {:ok, _} = TaskBoard.create(build_task(title: "T2"))

      tasks = TaskBoard.list(%{})
      assert length(tasks) >= 2
    end

    test "filters by status" do
      {:ok, t1} = TaskBoard.create(build_task())
      {:ok, _} = TaskBoard.checkout(t1.id, "agent")

      TaskBoard.create(build_task())

      in_progress = TaskBoard.list(%{status: :in_progress})
      assert Enum.all?(in_progress, &(&1.status == :in_progress))
    end

    test "filters by assigned_to" do
      {:ok, _} = TaskBoard.create(build_task(assigned_to: "alpha"))
      {:ok, _} = TaskBoard.create(build_task(assigned_to: "beta"))

      alpha_tasks = TaskBoard.list(%{assigned_to: "alpha"})
      assert Enum.all?(alpha_tasks, &(&1.assigned_to == "alpha"))
    end

    test "filters by created_by" do
      {:ok, _} = TaskBoard.create(build_task(created_by: "boss"))
      {:ok, _} = TaskBoard.create(build_task(created_by: "intern"))

      boss_tasks = TaskBoard.list(%{created_by: "boss"})
      assert Enum.all?(boss_tasks, &(&1.created_by == "boss"))
    end

    test "filters by company" do
      {:ok, _} = TaskBoard.create(build_task(company: "acme"))
      {:ok, _} = TaskBoard.create(build_task(company: "globex"))

      acme_tasks = TaskBoard.list(%{company: "acme"})
      assert Enum.all?(acme_tasks, &(Map.get(&1, :company) == "acme"))
    end

    test "combines multiple filters" do
      {:ok, _} = TaskBoard.create(build_task(assigned_to: "agent_x", company: "corp"))
      {:ok, _} = TaskBoard.create(build_task(assigned_to: "agent_x", company: "other"))

      tasks = TaskBoard.list(%{assigned_to: "agent_x", company: "corp"})
      assert length(tasks) >= 1
      assert Enum.all?(tasks, &(&1.assigned_to == "agent_x" and &1.company == "corp"))
    end

    test "returns tasks sorted by created_at descending" do
      {:ok, _} = TaskBoard.create(build_task(title: "First"))
      {:ok, _} = TaskBoard.create(build_task(title: "Second"))

      tasks = TaskBoard.list(%{})
      if length(tasks) >= 2 do
        [newer | [older | _]] = tasks
        assert DateTime.compare(newer.created_at, older.created_at) in [:gt, :eq]
      end
    end
  end

  describe "pending_for/1" do
    test "returns only pending tasks for the agent" do
      {:ok, _} = TaskBoard.create(build_task(assigned_to: "bot"))
      {:ok, t2} = TaskBoard.create(build_task(assigned_to: "bot"))
      {:ok, _} = TaskBoard.checkout(t2.id, "bot")

      pending = TaskBoard.pending_for("bot")
      assert Enum.all?(pending, &(&1.status == :pending and &1.assigned_to == "bot"))
    end
  end

  describe "in_progress_for/1" do
    test "returns only in_progress tasks for the agent" do
      {:ok, task} = TaskBoard.create(build_task(assigned_to: "bot"))
      {:ok, _} = TaskBoard.checkout(task.id, "bot")

      in_progress = TaskBoard.in_progress_for("bot")
      assert Enum.all?(in_progress, &(&1.status == :in_progress and &1.assigned_to == "bot"))
    end
  end

  # ── Goal Ancestry ────────────────────────────────────────

  describe "goal_ancestry/1" do
    test "returns empty for a root task" do
      {:ok, task} = TaskBoard.create(build_task())
      ancestry = TaskBoard.goal_ancestry(task.id)

      assert length(ancestry) == 1
      assert hd(ancestry).id == task.id
    end

    test "returns full chain for nested tasks" do
      {:ok, root} = TaskBoard.create(build_task(title: "Root"))
      {:ok, child} = TaskBoard.create(build_task(title: "Child", parent_task_id: root.id))
      {:ok, grandchild} = TaskBoard.create(build_task(title: "Grandchild", parent_task_id: child.id))

      ancestry = TaskBoard.goal_ancestry(grandchild.id)

      assert length(ancestry) == 3
      assert hd(ancestry).title == "Root"
      assert List.last(ancestry).title == "Grandchild"
    end

    test "returns single element for non-existent parent" do
      {:ok, task} = TaskBoard.create(build_task(parent_task_id: "task_nonexistent"))
      ancestry = TaskBoard.goal_ancestry(task.id)

      assert length(ancestry) == 1
    end
  end

  # ── Concurrent Operations ────────────────────────────────

  describe "concurrent operations" do
    test "multiple agents cannot checkout the same task" do
      {:ok, task} = TaskBoard.create(build_task())

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn -> TaskBoard.checkout(task.id, "agent_#{i}") end)
        end)
        |> Enum.map(&Task.await/1)

      successes = Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

      errors = Enum.count(results, fn
        {:error, _} -> true
        _ -> false
      end)

      assert successes == 1
      assert errors == 9
    end

    test "concurrent creates produce unique IDs" do
      tasks =
        1..20
        |> Enum.map(fn i ->
          Task.async(fn -> TaskBoard.create(build_task(title: "Concurrent #{i}")) end)
        end)
        |> Enum.map(&Task.await/1)
        |> Enum.map(fn {:ok, t} -> t.id end)

      assert length(Enum.uniq(tasks)) == 20
    end
  end
end

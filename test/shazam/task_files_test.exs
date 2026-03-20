defmodule Shazam.TaskFilesTest do
  use ExUnit.Case, async: false

  alias Shazam.TaskFiles

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "shazam_task_files_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

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

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  # ── write_task/1 ───────────────────────────────────────────

  describe "write_task/1" do
    test "creates .md with correct frontmatter", %{tmp_dir: tmp_dir} do
      task = %{
        id: "task_42",
        title: "Build login page",
        status: :pending,
        assigned_to: "dev1",
        created_by: "pm",
        company: "acme",
        description: "Implement the login page",
        result: nil,
        created_at: ~U[2026-01-15 10:00:00Z]
      }

      path = TaskFiles.write_task(task)

      assert File.exists?(path)
      assert path == Path.join([tmp_dir, ".shazam", "tasks", "task_42.md"])

      content = File.read!(path)
      assert content =~ "---"
      assert content =~ "id: task_42"
      assert content =~ "title: \"Build login page\""
      assert content =~ "status: pending"
      assert content =~ "assigned_to: dev1"
      assert content =~ "created_by: pm"
      assert content =~ "company: acme"
    end

    test "includes description in body" do
      task = %{
        id: "task_100",
        title: "My Task",
        status: :in_progress,
        assigned_to: "agent",
        created_by: "system",
        description: "A detailed description here",
        result: nil,
        created_at: DateTime.utc_now()
      }

      path = TaskFiles.write_task(task)
      content = File.read!(path)
      assert content =~ "## Description"
      assert content =~ "A detailed description here"
    end

    test "includes result section when result is present" do
      task = %{
        id: "task_101",
        title: "Done Task",
        status: :completed,
        assigned_to: "agent",
        created_by: "system",
        description: "Something",
        result: "Task completed successfully",
        created_at: DateTime.utc_now()
      }

      path = TaskFiles.write_task(task)
      content = File.read!(path)
      assert content =~ "## Result"
      assert content =~ "Task completed successfully"
    end
  end

  # ── read_all/0 ─────────────────────────────────────────────

  describe "read_all/0" do
    test "reads all .md files from directory" do
      task1 = %{id: "task_1", title: "First", status: :pending, assigned_to: "a", created_by: "b", description: "desc1", result: nil, created_at: DateTime.utc_now()}
      task2 = %{id: "task_2", title: "Second", status: :completed, assigned_to: "c", created_by: "d", description: "desc2", result: "done", created_at: DateTime.utc_now()}

      TaskFiles.write_task(task1)
      TaskFiles.write_task(task2)

      tasks = TaskFiles.read_all()
      assert length(tasks) == 2

      ids = Enum.map(tasks, & &1.id)
      assert "task_1" in ids
      assert "task_2" in ids
    end

    test "returns empty list for empty directory" do
      TaskFiles.ensure_dir()
      assert TaskFiles.read_all() == []
    end

    test "returns empty list when directory does not exist", %{tmp_dir: tmp_dir} do
      fresh = Path.join(tmp_dir, "nonexistent_workspace")
      Application.put_env(:shazam, :workspace, fresh)

      assert TaskFiles.read_all() == []
    end
  end

  # ── update_status/2 and update_status/3 ────────────────────

  describe "update_status/2" do
    test "changes status in frontmatter" do
      task = %{id: "task_upd", title: "Update Me", status: :pending, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      TaskFiles.update_status("task_upd", :in_progress)

      [updated] = TaskFiles.read_all()
      assert updated.status == "in_progress"
    end
  end

  describe "update_status/3" do
    test "changes status and adds result" do
      task = %{id: "task_res", title: "Result Me", status: :in_progress, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      TaskFiles.update_status("task_res", :completed, "All done!")

      [updated] = TaskFiles.read_all()
      assert updated.status == "completed"
      assert updated.result == "All done!"
    end

    test "adds completed_at when completing" do
      task = %{id: "task_cat", title: "Complete Me", status: :in_progress, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      TaskFiles.update_status("task_cat", :completed, "Finished")

      [updated] = TaskFiles.read_all()
      assert updated.completed_at != nil
    end

    test "adds completed_at when failing" do
      task = %{id: "task_fail", title: "Fail Me", status: :in_progress, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      TaskFiles.update_status("task_fail", :failed, "Error occurred")

      [updated] = TaskFiles.read_all()
      assert updated.completed_at != nil
    end
  end

  # ── delete_task/1 ──────────────────────────────────────────

  describe "delete_task/1" do
    test "removes the task file" do
      task = %{id: "task_del", title: "Delete Me", status: :pending, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      path = TaskFiles.write_task(task)

      assert File.exists?(path)

      TaskFiles.delete_task("task_del")

      refute File.exists?(path)
    end

    test "does nothing for non-existent task" do
      # Should not raise
      TaskFiles.delete_task("task_nonexistent")
    end
  end

  # ── sync_to_files/1 ───────────────────────────────────────

  describe "sync_to_files/1" do
    test "exports multiple tasks" do
      tasks = [
        %{id: "task_s1", title: "Sync 1", status: :pending, assigned_to: "a", created_by: "b", description: "d1", result: nil, created_at: DateTime.utc_now()},
        %{id: "task_s2", title: "Sync 2", status: :completed, assigned_to: "c", created_by: "d", description: "d2", result: "ok", created_at: DateTime.utc_now()}
      ]

      TaskFiles.sync_to_files(tasks)

      files = TaskFiles.read_all()
      assert length(files) == 2
    end
  end

  # ── sync_from_files/0 ─────────────────────────────────────

  describe "sync_from_files/0" do
    test "imports tasks into TaskBoard when running" do
      # Start the dependencies needed for sync_from_files
      ensure_started(Shazam.API.EventBus)
      ensure_started(Shazam.TaskBoard)
      Shazam.TaskBoard.clear_all()

      task = %{id: "task_imp", title: "Import Me", status: :pending, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      TaskFiles.sync_from_files()

      # Verify a task was imported (it creates a new one with a new ID)
      tasks = Shazam.TaskBoard.list(%{})
      assert Enum.any?(tasks, fn t -> t.title == "Import Me" end)
    end
  end

  # ── Edge cases ─────────────────────────────────────────────

  describe "edge cases" do
    test "handles files without frontmatter", %{tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, ".shazam", "tasks"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "bad.md"), "Just some text without frontmatter.")

      tasks = TaskFiles.read_all()
      # File without proper frontmatter should be rejected (nil filtered out)
      assert tasks == []
    end

    test "handles file with frontmatter but no id", %{tmp_dir: tmp_dir} do
      dir = Path.join([tmp_dir, ".shazam", "tasks"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "noid.md"), "---\ntitle: \"No ID\"\nstatus: pending\n---\n\nBody text.")

      tasks = TaskFiles.read_all()
      assert tasks == []
    end

    test "escapes quotes in title" do
      task = %{id: "task_q", title: "Task with \"quotes\"", status: :pending, assigned_to: "a", created_by: "b", description: "desc", result: nil, created_at: DateTime.utc_now()}
      TaskFiles.write_task(task)

      [parsed] = TaskFiles.read_all()
      assert parsed.title =~ "quotes"
    end
  end
end

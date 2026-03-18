defmodule Shazam.AgentInboxTest do
  use ExUnit.Case, async: false

  alias Shazam.AgentInbox

  setup do
    case GenServer.whereis(AgentInbox) do
      nil ->
        {:ok, _} = AgentInbox.start_link([])
      pid ->
        # Reset state by stopping and restarting
        GenServer.stop(pid, :normal)
        Process.sleep(10)
        case AgentInbox.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
    end

    :ok
  end

  # ── push/2 ───────────────────────────────────────────────

  describe "push/2" do
    test "enqueues a message for an agent" do
      assert :ok = AgentInbox.push("agent_a", "Hello from user")
    end

    test "enqueues multiple messages for the same agent" do
      :ok = AgentInbox.push("agent_b", "msg1")
      :ok = AgentInbox.push("agent_b", "msg2")
      :ok = AgentInbox.push("agent_b", "msg3")

      assert AgentInbox.has_pending?("agent_b")
    end

    test "enqueues messages for different agents independently" do
      :ok = AgentInbox.push("x", "for x")
      :ok = AgentInbox.push("y", "for y")

      assert AgentInbox.has_pending?("x")
      assert AgentInbox.has_pending?("y")
    end
  end

  # ── pop/1 ────────────────────────────────────────────────

  describe "pop/1" do
    test "returns nil for empty queue" do
      assert AgentInbox.pop("empty_agent") == nil
    end

    test "returns the first message in FIFO order" do
      AgentInbox.push("fifo", "first")
      AgentInbox.push("fifo", "second")

      entry = AgentInbox.pop("fifo")
      assert entry.message == "first"
    end

    test "subsequent pops return next messages" do
      AgentInbox.push("seq", "a")
      AgentInbox.push("seq", "b")
      AgentInbox.push("seq", "c")

      assert AgentInbox.pop("seq").message == "a"
      assert AgentInbox.pop("seq").message == "b"
      assert AgentInbox.pop("seq").message == "c"
      assert AgentInbox.pop("seq") == nil
    end

    test "popped entry includes a timestamp" do
      AgentInbox.push("ts_agent", "msg")
      entry = AgentInbox.pop("ts_agent")

      assert %DateTime{} = entry.timestamp
    end

    test "pop removes the message from the queue" do
      AgentInbox.push("removal", "msg")
      AgentInbox.pop("removal")

      refute AgentInbox.has_pending?("removal")
    end
  end

  # ── has_pending?/1 ───────────────────────────────────────

  describe "has_pending?/1" do
    test "returns false for agent with no messages" do
      refute AgentInbox.has_pending?("nobody")
    end

    test "returns true when messages are queued" do
      AgentInbox.push("check", "hello")
      assert AgentInbox.has_pending?("check")
    end

    test "returns false after all messages are popped" do
      AgentInbox.push("drain", "msg")
      AgentInbox.pop("drain")

      refute AgentInbox.has_pending?("drain")
    end
  end

  # ── pop_all/1 ────────────────────────────────────────────

  describe "pop_all/1" do
    test "returns empty list for agent with no messages" do
      assert AgentInbox.pop_all("none") == []
    end

    test "returns all messages and clears the queue" do
      AgentInbox.push("batch", "m1")
      AgentInbox.push("batch", "m2")
      AgentInbox.push("batch", "m3")

      messages = AgentInbox.pop_all("batch")
      assert length(messages) == 3
      assert Enum.map(messages, & &1.message) == ["m1", "m2", "m3"]

      # Queue should be empty now
      refute AgentInbox.has_pending?("batch")
      assert AgentInbox.pop_all("batch") == []
    end

    test "does not affect other agents' queues" do
      AgentInbox.push("alpha", "a_msg")
      AgentInbox.push("beta", "b_msg")

      AgentInbox.pop_all("alpha")

      assert AgentInbox.has_pending?("beta")
      refute AgentInbox.has_pending?("alpha")
    end
  end

  # ── Isolation between agents ────────────────────────────

  describe "isolation" do
    test "popping from one agent does not affect another" do
      AgentInbox.push("isolated_a", "msg_a")
      AgentInbox.push("isolated_b", "msg_b")

      entry = AgentInbox.pop("isolated_a")
      assert entry.message == "msg_a"

      entry_b = AgentInbox.pop("isolated_b")
      assert entry_b.message == "msg_b"
    end

    test "pop_all returns messages in insertion order" do
      for i <- 1..5 do
        AgentInbox.push("ordered", "msg_#{i}")
      end

      messages = AgentInbox.pop_all("ordered")
      texts = Enum.map(messages, & &1.message)
      assert texts == ["msg_1", "msg_2", "msg_3", "msg_4", "msg_5"]
    end
  end
end

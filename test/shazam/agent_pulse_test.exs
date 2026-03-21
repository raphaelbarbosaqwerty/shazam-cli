defmodule Shazam.AgentPulseTest do
  use ExUnit.Case, async: false

  alias Shazam.AgentPulse

  @moduletag :agent_pulse

  setup do
    ensure_started(Shazam.AgentPulse)

    # Clear any leftover state
    AgentPulse.clear("test_agent")
    AgentPulse.clear("stale_agent")
    AgentPulse.clear("active_agent")

    :ok
  end

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  describe "tick/1 and sparkline/1" do
    test "returns a string with sparkline characters after ticks" do
      AgentPulse.tick("test_agent")
      AgentPulse.tick("test_agent")
      AgentPulse.tick("test_agent")
      Process.sleep(50)

      result = AgentPulse.sparkline("test_agent")
      assert is_binary(result)
      assert String.length(result) > 0
      # Should contain sparkline characters
      assert Regex.match?(~r/[▁▂▃▄▅▆▇█]/, result)
    end

    test "returns empty string for unknown agent" do
      result = AgentPulse.sparkline("unknown_agent_#{System.unique_integer([:positive])}")
      assert result == ""
    end
  end

  describe "clear/1" do
    test "removes agent from tracking" do
      AgentPulse.tick("clear_test")
      Process.sleep(50)

      # Should have a sparkline
      assert AgentPulse.sparkline("clear_test") != ""

      AgentPulse.clear("clear_test")
      Process.sleep(50)

      # Should be gone
      assert AgentPulse.sparkline("clear_test") == ""
    end
  end

  describe "stalled?/1" do
    test "returns false for recently active agent" do
      AgentPulse.tick("active_agent")
      Process.sleep(50)

      refute AgentPulse.stalled?("active_agent")
    end

    test "returns false for unknown agent" do
      refute AgentPulse.stalled?("never_seen_agent_#{System.unique_integer([:positive])}")
    end
  end

  describe "all_sparklines/0" do
    test "returns map of agent sparklines" do
      AgentPulse.tick("spark_a")
      AgentPulse.tick("spark_b")
      Process.sleep(50)

      result = AgentPulse.all_sparklines()
      assert is_map(result)
      assert Map.has_key?(result, "spark_a")
      assert Map.has_key?(result, "spark_b")
      assert is_binary(result["spark_a"])
      assert is_binary(result["spark_b"])

      # Cleanup
      AgentPulse.clear("spark_a")
      AgentPulse.clear("spark_b")
    end
  end
end

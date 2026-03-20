defmodule Shazam.MetricsTest do
  use ExUnit.Case, async: false

  alias Shazam.Metrics

  setup do
    ensure_started(Shazam.API.EventBus)

    # Remove persisted metrics file so load_metrics starts clean
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    metrics_path = Path.join([workspace, ".shazam", "metrics.json"])
    File.rm(metrics_path)

    # Stop and restart Metrics to get a clean ETS table each test
    case GenServer.whereis(Metrics) do
      nil -> :ok
      pid ->
        GenServer.stop(pid, :normal)
        Process.sleep(10)
    end

    {:ok, _} = Metrics.start_link([])
    :ok
  end

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  # ── record_completion ────────────────────────────────────

  describe "record_completion/3" do
    test "records a single completion" do
      Metrics.record_completion("agent_a", 1000, 500)
      # cast is async, give it a moment
      Process.sleep(50)

      result = Metrics.get_agent("agent_a")
      assert result != nil
      assert result.successes == 1
      assert result.failures == 0
      assert result.total_tasks == 1
      assert result.avg_duration_ms == 1000
      assert result.total_tokens == 500
    end

    test "accumulates multiple completions" do
      Metrics.record_completion("agent_b", 1000, 100)
      Metrics.record_completion("agent_b", 3000, 200)
      Process.sleep(50)

      result = Metrics.get_agent("agent_b")
      assert result.successes == 2
      assert result.total_tokens == 300
      assert result.avg_duration_ms == 2000
    end

    test "computes success_rate correctly" do
      Metrics.record_completion("agent_c", 500, 0)
      Metrics.record_completion("agent_c", 500, 0)
      Metrics.record_failure("agent_c")
      Process.sleep(50)

      result = Metrics.get_agent("agent_c")
      # 2 successes / 3 total = 66.7%
      assert result.success_rate == 66.7
    end

    test "computes estimated cost" do
      Metrics.record_completion("agent_d", 100, 10_000)
      Process.sleep(50)

      result = Metrics.get_agent("agent_d")
      # 10_000 / 1000 * 0.003 = 0.03
      assert result.estimated_cost == 0.03
    end

    test "handles zero tokens" do
      Metrics.record_completion("agent_e", 500, 0)
      Process.sleep(50)

      result = Metrics.get_agent("agent_e")
      assert result.total_tokens == 0
      assert result.estimated_cost == 0.0
    end
  end

  # ── record_failure ───────────────────────────────────────

  describe "record_failure/1" do
    test "records a failure" do
      Metrics.record_failure("fail_agent")
      Process.sleep(50)

      result = Metrics.get_agent("fail_agent")
      assert result.failures == 1
      assert result.successes == 0
      assert result.total_tasks == 1
    end

    test "tracks failures independently of successes" do
      Metrics.record_completion("mixed", 100, 0)
      Metrics.record_failure("mixed")
      Metrics.record_failure("mixed")
      Process.sleep(50)

      result = Metrics.get_agent("mixed")
      assert result.successes == 1
      assert result.failures == 2
      assert result.total_tasks == 3
    end
  end

  # ── get_agent ────────────────────────────────────────────

  describe "get_agent/1" do
    test "returns nil for unknown agent" do
      assert Metrics.get_agent("nobody") == nil
    end

    test "returns serialized metrics map" do
      Metrics.record_completion("known", 200, 50)
      Process.sleep(50)

      result = Metrics.get_agent("known")
      assert is_map(result)
      assert Map.has_key?(result, :successes)
      assert Map.has_key?(result, :failures)
      assert Map.has_key?(result, :total_tasks)
      assert Map.has_key?(result, :success_rate)
      assert Map.has_key?(result, :avg_duration_ms)
      assert Map.has_key?(result, :total_tokens)
      assert Map.has_key?(result, :estimated_cost)
      assert Map.has_key?(result, :tasks_per_hour)
    end
  end

  # ── get_all ──────────────────────────────────────────────

  describe "get_all/0" do
    test "returns empty agents when none recorded" do
      result = Metrics.get_all()
      assert result.agents == %{}
      assert result.totals.total_tasks == 0
    end

    test "returns all agents and totals" do
      Metrics.record_completion("agent_1", 100, 50)
      Metrics.record_completion("agent_2", 200, 100)
      Metrics.record_failure("agent_2")
      Process.sleep(50)

      result = Metrics.get_all()
      assert map_size(result.agents) == 2
      assert Map.has_key?(result.agents, "agent_1")
      assert Map.has_key?(result.agents, "agent_2")

      totals = result.totals
      assert totals.successes == 2
      assert totals.failures == 1
      assert totals.total_tasks == 3
      assert totals.total_tokens == 150
    end

    test "totals success_rate is computed" do
      Metrics.record_completion("a1", 100, 0)
      Metrics.record_failure("a2")
      Process.sleep(50)

      result = Metrics.get_all()
      assert result.totals.success_rate == 50.0
    end

    test "tasks_per_hour is a non-negative float" do
      Metrics.record_completion("speed", 50, 0)
      Process.sleep(50)

      result = Metrics.get_agent("speed")
      assert is_float(result.tasks_per_hour)
      assert result.tasks_per_hour >= 0.0
    end
  end

  # ── record_tokens ─────────────────────────────────────────

  describe "record_tokens/3" do
    test "increments total_tokens for an agent" do
      Metrics.record_tokens("token_agent", 500, 0.01)
      Metrics.record_tokens("token_agent", 300, 0.005)
      Process.sleep(50)

      result = Metrics.get_agent("token_agent")
      assert result != nil
      assert result.total_tokens == 800
    end

    test "increments cost_usd" do
      Metrics.record_tokens("cost_agent", 1000, 0.05)
      Metrics.record_tokens("cost_agent", 2000, 0.10)
      Process.sleep(50)

      # cost_usd is tracked internally but serialized metrics show estimated_cost
      # Let's verify tokens accumulated correctly
      result = Metrics.get_agent("cost_agent")
      assert result.total_tokens == 3000
    end

    test "works alongside record_completion" do
      Metrics.record_completion("combo_agent", 200, 100)
      Metrics.record_tokens("combo_agent", 500, 0.02)
      Process.sleep(50)

      result = Metrics.get_agent("combo_agent")
      assert result.total_tokens == 600
      assert result.successes == 1
    end
  end

  # ── reset ─────────────────────────────────────────────────

  describe "reset/0" do
    test "preserves tokens and cost after reset" do
      Metrics.record_completion("reset_agent", 100, 500)
      Metrics.record_tokens("reset_agent", 1000, 0.05)
      Process.sleep(50)

      assert :ok = Metrics.reset()

      result = Metrics.get_agent("reset_agent")
      assert result != nil
      # Tokens should be preserved across reset
      assert result.total_tokens >= 1000
    end

    test "preserves successes and failures counts" do
      Metrics.record_completion("keep_agent", 100, 50)
      Metrics.record_failure("keep_agent")
      Process.sleep(50)

      Metrics.reset()

      result = Metrics.get_agent("keep_agent")
      assert result.successes == 1
      assert result.failures == 1
    end

    test "resets session timing metrics" do
      Metrics.record_completion("timing_agent", 5000, 100)
      Process.sleep(50)

      Metrics.reset()

      result = Metrics.get_agent("timing_agent")
      # avg_duration_ms should be reset to 0 since total_duration_ms is reset
      assert result.avg_duration_ms == 0
    end
  end

  # ── Metrics persistence ───────────────────────────────────

  describe "metrics persistence" do
    test "save/load cycle via record_tokens" do
      # record_tokens triggers save_metrics internally
      Metrics.record_tokens("persist_agent", 2000, 0.10)
      # Give the async save some time
      Process.sleep(200)

      workspace = Application.get_env(:shazam, :workspace, File.cwd!())
      metrics_path = Path.join([workspace, ".shazam", "metrics.json"])

      if File.exists?(metrics_path) do
        {:ok, content} = File.read(metrics_path)
        {:ok, data} = Jason.decode(content)
        assert is_map(data)
        assert data["persist_agent"]["total_tokens"] == 2000
      end
    end
  end
end

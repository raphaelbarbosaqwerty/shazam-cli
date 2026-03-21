defmodule Shazam.CircuitBreaker do
  @moduledoc """
  Circuit breaker for RalphLoop task execution.

  If 3 consecutive tasks fail with the same error pattern, auto-pauses
  the RalphLoop and notifies the user via EventBus.
  """

  use GenServer
  require Logger

  @default_threshold 3

  # ── Public API ──────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a failure. Increments counter and trips if threshold reached."
  def record_failure(error) do
    GenServer.cast(__MODULE__, {:record_failure, error})
  end

  @doc "Record a success. Resets the consecutive failure counter."
  def record_success do
    GenServer.cast(__MODULE__, :record_success)
  end

  @doc "Check if the circuit breaker is tripped (open)."
  def tripped? do
    GenServer.call(__MODULE__, :tripped?)
  catch
    :exit, _ -> false
  end

  @doc "Manually reset the circuit breaker."
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> :ok
  end

  @doc "Get the current circuit breaker status."
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{consecutive_failures: 0, last_error: nil, tripped: false, threshold: @default_threshold}
  end

  # ── Callbacks ───────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{
      consecutive_failures: 0,
      last_error: nil,
      tripped: false,
      threshold: @default_threshold
    }}
  end

  @impl true
  def handle_cast({:record_failure, error}, state) do
    failures = state.consecutive_failures + 1
    state = %{state | consecutive_failures: failures, last_error: error}

    if failures >= state.threshold and not state.tripped do
      Logger.error("[CircuitBreaker] Tripped after #{failures} consecutive failures. Last error: #{inspect(error, limit: 200)}")
      Shazam.FileLogger.warn("Circuit breaker tripped — #{failures} consecutive failures: #{inspect(error, limit: 200)}")

      Shazam.API.EventBus.broadcast(%{
        event: "circuit_breaker_tripped",
        message: "Circuit breaker tripped — #{failures} consecutive failures",
        last_error: inspect(error, limit: 200)
      })

      # Auto-pause all running RalphLoops
      try do
        Registry.select(Shazam.RalphLoopRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn company_name ->
          try do
            Shazam.RalphLoop.pause(company_name)
            Logger.warning("[CircuitBreaker] Auto-paused RalphLoop for #{company_name}")
          catch
            _, _ -> :ok
          end
        end)
      catch
        _, _ -> :ok
      end

      {:noreply, %{state | tripped: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:record_success, _state) do
    {:noreply, %{
      consecutive_failures: 0,
      last_error: nil,
      tripped: false,
      threshold: @default_threshold
    }}
  end

  @impl true
  def handle_call(:tripped?, _from, state) do
    {:reply, state.tripped, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    Logger.info("[CircuitBreaker] Manually reset")
    Shazam.API.EventBus.broadcast(%{event: "circuit_breaker_reset"})
    {:reply, :ok, %{
      consecutive_failures: 0,
      last_error: nil,
      tripped: false,
      threshold: @default_threshold
    }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end
end

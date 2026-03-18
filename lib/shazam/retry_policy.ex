defmodule Shazam.RetryPolicy do
  @moduledoc """
  Intelligent retry with exponential backoff for failed tasks.
  Decides whether a task should be retried, computes the next delay,
  and builds context from previous errors for the retry prompt.
  """

  @non_retryable_patterns [
    "budget exhausted",
    "cancelled",
    "rejected"
  ]

  @backoff_delays [5_000, 15_000, 30_000]

  @doc """
  Returns true if the task should be retried based on:
  - retry_count < max_retries
  - error is not in the non-retryable list
  """
  def should_retry?(task) do
    retry_count = Map.get(task, :retry_count, 0)
    max_retries = Map.get(task, :max_retries, 2)

    retry_count < max_retries and not non_retryable_error?(task)
  end

  @doc """
  Returns the delay in milliseconds for the next retry attempt.
  Exponential backoff: 5s, 15s, 30s (capped at 30s for higher counts).
  """
  def next_delay(retry_count) when is_integer(retry_count) and retry_count >= 0 do
    index = min(retry_count, length(@backoff_delays) - 1)
    Enum.at(@backoff_delays, index)
  end

  @doc """
  Builds a retry context string from the previous error and partial output.
  This is prepended to the task description on retry so the agent knows
  what went wrong previously.
  """
  def build_retry_context(task) do
    last_error = Map.get(task, :last_error)
    retry_count = Map.get(task, :retry_count, 0)

    if last_error do
      error_str = format_error(last_error)

      """
      [RETRY #{retry_count}/#{Map.get(task, :max_retries, 2)}] Previous attempt failed with error:
      #{error_str}

      Please try a different approach or fix the issue that caused the failure.

      ---
      """
    else
      ""
    end
  end

  # --- Private ---

  defp non_retryable_error?(task) do
    error_str =
      task
      |> Map.get(:last_error, "")
      |> format_error()
      |> String.downcase()

    Enum.any?(@non_retryable_patterns, fn pattern ->
      String.contains?(error_str, pattern)
    end)
  end

  defp format_error(nil), do: ""
  defp format_error(error) when is_binary(error), do: error
  defp format_error({:error, reason}), do: inspect(reason, limit: 300)
  defp format_error({:process_died, reason}), do: "Process died: #{inspect(reason, limit: 300)}"
  defp format_error(error), do: inspect(error, limit: 300)
end

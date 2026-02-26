defmodule Cyclium.Strategy.Retry do
  @moduledoc """
  Lightweight retry helper for strategies.

  Tracks attempt counts inside the strategy's state map (under `:__retries`)
  so strategies can declaratively retry failed steps without hand-rolling counters.

  ## Usage

      alias Cyclium.Strategy.Retry

      # On synthesis success — reset the counter
      def handle_result(state, %{kind: :synthesis}, {:ok, result}) do
        {:ok, state |> Retry.reset(:synthesis) |> Map.put(:assessment, result)}
      end

      # On synthesis failure — retry up to 3 times with 2s backoff
      def handle_result(state, %{kind: :synthesis} = step, {:error, _}) do
        case Retry.check(state, step, max_attempts: 3, backoff_ms: 2_000) do
          {:retry, new_state}             -> {:retry, new_state}
          {:give_up, _attempts, new_state} -> {:abort, "synthesis_failed_after_retries"}
        end
      end

  The strategy's `next_step/2` doesn't need special logic — when `handle_result`
  returns `{:retry, state}`, the runner calls `do_loop` which calls `next_step`
  again. The strategy should naturally re-emit the same step type based on its
  phase/state (which hasn't changed, only `:__retries` was updated).
  """

  @retry_key :__retries

  @doc """
  Evaluates whether a failed step should be retried.

  Returns:
    - `{:retry, updated_state}` — attempt recorded, caller should return `{:retry, state}` from `handle_result`
    - `{:give_up, attempt_count, updated_state}` — max attempts exhausted, counter reset

  ## Options

    - `:max_attempts` — total attempts including the original (default `3`)
    - `:backoff_ms` — milliseconds to sleep before retry, `0` for immediate (default `0`)
    - `:step_key` — key for tracking this retry series (default `step.kind`)
  """
  def check(state, step, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 3)
    backoff = Keyword.get(opts, :backoff_ms, 0)
    key = Keyword.get(opts, :step_key, step_key(step))

    retries = Map.get(state, @retry_key, %{})
    attempts = Map.get(retries, key, 0) + 1

    if attempts < max do
      if backoff > 0, do: Process.sleep(backoff)
      new_retries = Map.put(retries, key, attempts)
      {:retry, Map.put(state, @retry_key, new_retries)}
    else
      new_retries = Map.delete(retries, key)
      {:give_up, attempts, Map.put(state, @retry_key, new_retries)}
    end
  end

  @doc """
  Resets retry tracking for a given key. Call on success to clear the counter
  so a later failure of the same step kind gets fresh attempts.
  """
  def reset(state, key) do
    retries = Map.get(state, @retry_key, %{})
    Map.put(state, @retry_key, Map.delete(retries, key))
  end

  @doc """
  Resets all retry tracking.
  """
  def reset_all(state) do
    Map.delete(state, @retry_key)
  end

  defp step_key(%{kind: kind}), do: kind
  defp step_key(step) when is_map(step), do: Map.get(step, :kind, :unknown)
end

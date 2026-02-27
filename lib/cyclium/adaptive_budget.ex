defmodule Cyclium.AdaptiveBudget do
  @moduledoc """
  ETS-backed advisory budget tracking.

  Tracks actual resource usage (turns, tokens, wall time) across episodes
  and recommends budgets based on historical p95 values. Does not
  automatically adjust budgets — advisory only.

  ## Usage

      # After episode completion:
      Cyclium.AdaptiveBudget.record(:my_actor, :check_health, %{
        turns_used: 4,
        tokens_used: 8_500,
        wall_ms: 15_000
      })

      # Get recommendation:
      Cyclium.AdaptiveBudget.recommend(:my_actor, :check_health)
      # => %{max_turns: 8, max_tokens: 18_000, max_wall_ms: 45_000}

      # Get detailed stats:
      Cyclium.AdaptiveBudget.stats(:my_actor, :check_health)
  """

  @table :cyclium_budget_history
  @max_samples 100

  @doc "Idempotent ETS table creation."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ref ->
        @table
    end
  end

  @doc """
  Record resource usage for an episode.

  `usage` should include any of:
    - `:turns_used` — number of turns consumed
    - `:tokens_used` — number of tokens consumed
    - `:wall_ms` — wall-clock duration in milliseconds
  """
  def record(actor_id, expectation_id, usage) when is_map(usage) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, samples}] ->
        updated = [usage | samples] |> Enum.take(@max_samples)
        :ets.insert(@table, {key, updated})

      [] ->
        :ets.insert(@table, {key, [usage]})
    end

    :ok
  end

  @doc """
  Recommend budgets based on historical p95 usage with headroom.

  Returns a budget map or `nil` if insufficient samples (< 5).
  Adds 25% headroom above p95 values.
  """
  def recommend(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, samples}] when length(samples) >= 5 ->
        p95 = percentile(samples, 0.95)

        %{
          max_turns: ceil(p95.turns_used * 1.25),
          max_tokens: ceil(p95.tokens_used * 1.25),
          max_wall_ms: ceil(p95.wall_ms * 1.25)
        }

      _ ->
        nil
    end
  end

  @doc """
  Get detailed usage statistics.
  """
  def stats(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, samples}] when samples != [] ->
        %{
          samples: length(samples),
          p50: percentile(samples, 0.50),
          p95: percentile(samples, 0.95),
          max: max_values(samples)
        }

      _ ->
        %{samples: 0, p50: nil, p95: nil, max: nil}
    end
  end

  # --- Private ---

  defp percentile(samples, pct) do
    %{
      turns_used: percentile_of(samples, :turns_used, pct),
      tokens_used: percentile_of(samples, :tokens_used, pct),
      wall_ms: percentile_of(samples, :wall_ms, pct)
    }
  end

  defp percentile_of(samples, key, pct) do
    values =
      samples
      |> Enum.map(&Map.get(&1, key, 0))
      |> Enum.sort()

    if values == [] do
      0
    else
      idx = trunc(length(values) * pct) |> max(0) |> min(length(values) - 1)
      Enum.at(values, idx)
    end
  end

  defp max_values(samples) do
    %{
      turns_used: samples |> Enum.map(&Map.get(&1, :turns_used, 0)) |> Enum.max(),
      tokens_used: samples |> Enum.map(&Map.get(&1, :tokens_used, 0)) |> Enum.max(),
      wall_ms: samples |> Enum.map(&Map.get(&1, :wall_ms, 0)) |> Enum.max()
    }
  end
end

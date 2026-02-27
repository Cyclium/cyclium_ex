defmodule Cyclium.ServiceLevels do
  @moduledoc """
  ETS-backed performance objectives tracking per expectation.

  Tracks episode duration and success rate, and detects breaches
  against declared performance objectives.

  ## Configuration

  Set `service_levels` on an expectation:

      expect :check_health,
        service_levels: %{max_duration_ms: 30_000, success_rate: 0.95, window_episodes: 50}

  ## ETS layout

  Key: `{actor_id, expectation_id}`
  Value: `%{config: map, samples: [map], ...}`
  """

  @table :cyclium_service_level_metrics

  @doc "Idempotent ETS table creation."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ref ->
        @table
    end
  end

  @doc "Register performance objectives config for an expectation."
  def register(actor_id, expectation_id, config) when is_map(config) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, state}] ->
        :ets.insert(@table, {key, %{state | config: config}})

      [] ->
        :ets.insert(@table, {key, %{config: config, samples: []}})
    end

    :ok
  end

  @doc """
  Record an episode outcome.

  `measurements` should include:
    - `:duration_ms` — episode wall-clock time in milliseconds
    - `:success` — boolean
  """
  def record(actor_id, expectation_id, measurements) when is_map(measurements) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, state}] ->
        window = Map.get(state.config, :window_episodes, 100)
        samples = [measurements | state.samples] |> Enum.take(window)
        :ets.insert(@table, {key, %{state | samples: samples}})

      [] ->
        :ets.insert(@table, {key, %{config: %{}, samples: [measurements]}})
    end

    :ok
  end

  @doc """
  Check if performance objectives are being met.

  Returns `:ok` or `{:breach, details}`.
  """
  def check(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, %{config: config, samples: samples}}] when samples != [] ->
        check_breaches(config, samples)

      _ ->
        :ok
    end
  end

  @doc """
  Get current metrics for an expectation.
  """
  def metrics(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, %{samples: samples}}] when samples != [] ->
        compute_metrics(samples)

      _ ->
        %{success_rate: nil, p95_duration_ms: nil, sample_count: 0}
    end
  end

  # --- Private ---

  defp check_breaches(config, samples) do
    metrics = compute_metrics(samples)

    cond do
      breach = check_success_rate(config, metrics) ->
        {:breach, breach}

      breach = check_duration(config, metrics) ->
        {:breach, breach}

      true ->
        :ok
    end
  end

  defp check_success_rate(%{success_rate: threshold}, %{success_rate: actual})
       when is_float(threshold) and is_float(actual) and actual < threshold do
    %{type: :success_rate, current: actual, threshold: threshold}
  end

  defp check_success_rate(_, _), do: nil

  defp check_duration(%{max_duration_ms: threshold}, %{p95_duration_ms: actual})
       when is_number(threshold) and is_number(actual) and actual > threshold do
    %{type: :duration, current: actual, threshold: threshold}
  end

  defp check_duration(_, _), do: nil

  defp compute_metrics(samples) do
    count = length(samples)
    successes = Enum.count(samples, & &1[:success])

    durations =
      samples
      |> Enum.map(& &1[:duration_ms])
      |> Enum.filter(&is_number/1)
      |> Enum.sort()

    p95 =
      if durations != [] do
        idx = trunc(length(durations) * 0.95) |> max(0) |> min(length(durations) - 1)
        Enum.at(durations, idx)
      end

    %{
      success_rate: if(count > 0, do: successes / count, else: nil),
      p95_duration_ms: p95,
      sample_count: count
    }
  end
end

defmodule Cyclium.CircuitBreaker do
  @moduledoc """
  ETS-backed per-expectation circuit breaker.

  States: `:closed` → `:open` → `:half_open` → `:closed`.

  When consecutive failures exceed the threshold, the circuit opens and
  rejects new episodes. After `half_open_after_ms`, the circuit enters
  `:half_open` — allowing one probe episode. If it succeeds, the circuit
  closes; if it fails, the circuit reopens.

  ## Configuration

  Set `circuit_breaker` on an expectation:

      expect :check_health,
        circuit_breaker: %{threshold: 5, half_open_after_ms: 60_000}

  ## ETS layout

  Key: `{actor_id, expectation_id}`
  Value: `%{state: atom, consecutive_failures: int, opened_at: DateTime | nil}`
  """

  @table :cyclium_circuit_breakers

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
  Check if an episode is allowed to fire.

  Returns `:ok` or `{:error, :circuit_open}`.
  """
  def allow?(actor_id, expectation_id, config) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, %{state: :closed}}] ->
        :ok

      [{^key, %{state: :half_open}}] ->
        # Allow one probe
        :ok

      [{^key, %{state: :open, opened_at: opened_at}}] ->
        half_open_after_ms = Map.get(config, :half_open_after_ms, 60_000)
        elapsed = DateTime.diff(DateTime.utc_now(), opened_at, :millisecond)

        if elapsed >= half_open_after_ms do
          # Transition to half_open
          :ets.insert(
            @table,
            {key, %{state: :half_open, consecutive_failures: 0, opened_at: opened_at}}
          )

          :telemetry.execute(
            [:cyclium, :circuit_breaker, :half_open],
            %{},
            %{actor_id: actor_id, expectation_id: expectation_id}
          )

          :ok
        else
          :telemetry.execute(
            [:cyclium, :circuit_breaker, :rejected],
            %{},
            %{actor_id: actor_id, expectation_id: expectation_id}
          )

          {:error, :circuit_open}
        end

      [] ->
        :ok
    end
  end

  @doc "Record a successful episode. Resets the circuit to `:closed`."
  def record_success(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, %{state: state}}] when state in [:half_open, :open] ->
        :ets.insert(@table, {key, %{state: :closed, consecutive_failures: 0, opened_at: nil}})

        :telemetry.execute(
          [:cyclium, :circuit_breaker, :closed],
          %{},
          %{actor_id: actor_id, expectation_id: expectation_id}
        )

        :ok

      [{^key, _}] ->
        :ets.insert(@table, {key, %{state: :closed, consecutive_failures: 0, opened_at: nil}})
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Record a failed episode. Increments failure count and may trip the circuit.

  When the circuit trips and `cancel_in_flight: true` is set in config,
  running/blocked episodes for this actor+expectation are automatically canceled.
  """
  def record_failure(actor_id, expectation_id, config) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}
    threshold = Map.get(config, :threshold, 5)

    current =
      case :ets.lookup(@table, key) do
        [{^key, state}] -> state
        [] -> %{state: :closed, consecutive_failures: 0, opened_at: nil}
      end

    new_failures = current.consecutive_failures + 1

    if new_failures >= threshold do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      :ets.insert(
        @table,
        {key, %{state: :open, consecutive_failures: new_failures, opened_at: now}}
      )

      :telemetry.execute(
        [:cyclium, :circuit_breaker, :opened],
        %{consecutive_failures: new_failures},
        %{actor_id: actor_id, expectation_id: expectation_id}
      )

      # Cancel in-flight episodes if configured
      if Map.get(config, :cancel_in_flight, false) do
        cancel_in_flight(actor_id, expectation_id)
      end

      :tripped
    else
      :ets.insert(@table, {key, %{current | consecutive_failures: new_failures}})
      :ok
    end
  end

  @doc "Get the current circuit state for an expectation."
  def get_state(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, state}] -> state
      [] -> %{state: :closed, consecutive_failures: 0, opened_at: nil}
    end
  end

  # --- Private ---

  defp cancel_in_flight(actor_id, expectation_id) do
    Task.start(fn ->
      case Cyclium.Episodes.cancel_related(actor_id, expectation_id, "circuit_breaker_tripped") do
        {:ok, count} when count > 0 ->
          require Logger

          Logger.info("Circuit breaker canceled #{count} in-flight episode(s)",
            cyclium_actor_id: actor_id,
            cyclium_expectation_id: expectation_id
          )

          Cyclium.Bus.broadcast("circuit_breaker.canceled_episodes", %{
            actor_id: actor_id,
            expectation_id: expectation_id,
            canceled_count: count
          })

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end
end

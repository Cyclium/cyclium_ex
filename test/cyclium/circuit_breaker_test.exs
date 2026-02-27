defmodule Cyclium.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Cyclium.CircuitBreaker

  @actor_id "test_actor"
  @exp_id :check_health
  @config %{threshold: 3, half_open_after_ms: 100}

  setup do
    CircuitBreaker.ensure_table()
    # Clear state for this key
    :ets.delete(:cyclium_circuit_breakers, {to_string(@actor_id), to_string(@exp_id)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  describe "initial state" do
    test "starts closed" do
      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :closed
      assert state.consecutive_failures == 0
    end

    test "allow? returns :ok when closed" do
      assert :ok = CircuitBreaker.allow?(@actor_id, @exp_id, @config)
    end
  end

  describe "failure tracking" do
    test "records failures without tripping below threshold" do
      assert :ok = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      assert :ok = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :closed
      assert state.consecutive_failures == 2
    end

    test "trips circuit at threshold" do
      assert :ok = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      assert :ok = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      assert :tripped = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :open
      assert state.consecutive_failures == 3
      assert state.opened_at != nil
    end

    test "rejects episodes when open" do
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      assert :tripped = CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :open

      # Use a longer half_open_after_ms to avoid timing issues
      config = %{threshold: 3, half_open_after_ms: 60_000}
      assert {:error, :circuit_open} = CircuitBreaker.allow?(@actor_id, @exp_id, config)
    end
  end

  describe "recovery" do
    test "success resets to closed" do
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      assert CircuitBreaker.get_state(@actor_id, @exp_id).state == :open

      CircuitBreaker.record_success(@actor_id, @exp_id)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :closed
      assert state.consecutive_failures == 0
    end

    test "transitions to half_open after timeout" do
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      # Use long timeout to verify rejection first
      long_config = %{threshold: 3, half_open_after_ms: 60_000}
      assert {:error, :circuit_open} = CircuitBreaker.allow?(@actor_id, @exp_id, long_config)

      # Now use short timeout and wait for it to expire
      short_config = %{threshold: 3, half_open_after_ms: 50}
      Process.sleep(100)

      assert :ok = CircuitBreaker.allow?(@actor_id, @exp_id, short_config)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :half_open
    end

    test "half_open closes on success" do
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      short_config = %{threshold: 3, half_open_after_ms: 50}
      Process.sleep(100)
      CircuitBreaker.allow?(@actor_id, @exp_id, short_config)

      assert CircuitBreaker.get_state(@actor_id, @exp_id).state == :half_open

      CircuitBreaker.record_success(@actor_id, @exp_id)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :closed
    end

    test "half_open reopens on failure" do
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      short_config = %{threshold: 3, half_open_after_ms: 50}
      Process.sleep(100)
      CircuitBreaker.allow?(@actor_id, @exp_id, short_config)

      assert CircuitBreaker.get_state(@actor_id, @exp_id).state == :half_open

      # Failures in half_open accumulate toward threshold
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)
      CircuitBreaker.record_failure(@actor_id, @exp_id, @config)

      state = CircuitBreaker.get_state(@actor_id, @exp_id)
      assert state.state == :open
    end
  end

  describe "telemetry events" do
    test "circuit breaker events are declared" do
      events = Cyclium.Telemetry.events()
      assert [:cyclium, :circuit_breaker, :opened] in events
      assert [:cyclium, :circuit_breaker, :closed] in events
      assert [:cyclium, :circuit_breaker, :half_open] in events
      assert [:cyclium, :circuit_breaker, :rejected] in events
    end
  end
end

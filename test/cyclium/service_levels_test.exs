defmodule Cyclium.ServiceLevelsTest do
  use ExUnit.Case, async: false

  alias Cyclium.ServiceLevels

  @actor_id "test_actor"
  @exp_id :check_health

  setup do
    ServiceLevels.ensure_table()
    :ets.delete(:cyclium_service_level_metrics, {to_string(@actor_id), to_string(@exp_id)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  describe "register/3 and metrics/2" do
    test "registers config and returns empty metrics initially" do
      ServiceLevels.register(@actor_id, @exp_id, %{
        max_duration_ms: 30_000,
        success_rate: 0.95,
        window_episodes: 50
      })

      metrics = ServiceLevels.metrics(@actor_id, @exp_id)
      assert metrics.sample_count == 0
      assert metrics.success_rate == nil
    end
  end

  describe "record/3" do
    test "records samples and computes metrics" do
      ServiceLevels.register(@actor_id, @exp_id, %{window_episodes: 10})

      for i <- 1..5 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: i * 100, success: true})
      end

      metrics = ServiceLevels.metrics(@actor_id, @exp_id)
      assert metrics.sample_count == 5
      assert metrics.success_rate == 1.0
      assert is_number(metrics.p95_duration_ms)
    end

    test "respects window size" do
      ServiceLevels.register(@actor_id, @exp_id, %{window_episodes: 3})

      for i <- 1..5 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: i * 100, success: true})
      end

      metrics = ServiceLevels.metrics(@actor_id, @exp_id)
      assert metrics.sample_count == 3
    end
  end

  describe "check/2" do
    test "returns :ok when within objectives" do
      ServiceLevels.register(@actor_id, @exp_id, %{
        max_duration_ms: 1000,
        success_rate: 0.9,
        window_episodes: 10
      })

      for _ <- 1..10 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: 500, success: true})
      end

      assert :ok = ServiceLevels.check(@actor_id, @exp_id)
    end

    test "detects success rate breach" do
      ServiceLevels.register(@actor_id, @exp_id, %{
        success_rate: 0.9,
        window_episodes: 10
      })

      # 5 successes, 5 failures = 50% success rate
      for _ <- 1..5 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: 100, success: true})
      end

      for _ <- 1..5 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: 100, success: false})
      end

      assert {:breach, details} = ServiceLevels.check(@actor_id, @exp_id)
      assert details.type == :success_rate
      assert details.current == 0.5
      assert details.threshold == 0.9
    end

    test "detects duration breach" do
      ServiceLevels.register(@actor_id, @exp_id, %{
        max_duration_ms: 1000,
        window_episodes: 10
      })

      for _ <- 1..10 do
        ServiceLevels.record(@actor_id, @exp_id, %{duration_ms: 5000, success: true})
      end

      assert {:breach, details} = ServiceLevels.check(@actor_id, @exp_id)
      assert details.type == :duration
      assert details.current == 5000
      assert details.threshold == 1000
    end

    test "returns :ok with no samples" do
      assert :ok = ServiceLevels.check(@actor_id, @exp_id)
    end
  end

  describe "telemetry" do
    test "breach event is declared" do
      events = Cyclium.Telemetry.events()
      assert [:cyclium, :service_levels, :breach] in events
    end
  end
end

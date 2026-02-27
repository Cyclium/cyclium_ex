defmodule Cyclium.AdaptiveBudgetTest do
  use ExUnit.Case, async: false

  alias Cyclium.AdaptiveBudget

  @actor_id "test_actor"
  @exp_id :check_health

  setup do
    AdaptiveBudget.ensure_table()
    :ets.delete(:cyclium_budget_history, {to_string(@actor_id), to_string(@exp_id)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  describe "record/3 and stats/2" do
    test "returns empty stats with no samples" do
      stats = AdaptiveBudget.stats(@actor_id, @exp_id)
      assert stats.samples == 0
      assert stats.p50 == nil
    end

    test "records and tracks samples" do
      for i <- 1..10 do
        AdaptiveBudget.record(@actor_id, @exp_id, %{
          turns_used: i,
          tokens_used: i * 1000,
          wall_ms: i * 500
        })
      end

      stats = AdaptiveBudget.stats(@actor_id, @exp_id)
      assert stats.samples == 10
      assert stats.max.turns_used == 10
      assert stats.max.tokens_used == 10_000
      assert stats.max.wall_ms == 5_000
    end

    test "caps at max_samples (100)" do
      for i <- 1..120 do
        AdaptiveBudget.record(@actor_id, @exp_id, %{
          turns_used: i,
          tokens_used: i * 100,
          wall_ms: i * 50
        })
      end

      stats = AdaptiveBudget.stats(@actor_id, @exp_id)
      assert stats.samples == 100
    end
  end

  describe "recommend/2" do
    test "returns nil with insufficient samples" do
      for i <- 1..4 do
        AdaptiveBudget.record(@actor_id, @exp_id, %{
          turns_used: i,
          tokens_used: i * 1000,
          wall_ms: i * 500
        })
      end

      assert AdaptiveBudget.recommend(@actor_id, @exp_id) == nil
    end

    test "returns p95-based recommendation with headroom" do
      for _i <- 1..20 do
        AdaptiveBudget.record(@actor_id, @exp_id, %{
          turns_used: 4,
          tokens_used: 8_000,
          wall_ms: 15_000
        })
      end

      rec = AdaptiveBudget.recommend(@actor_id, @exp_id)
      assert rec != nil
      # p95 of uniform = 4, with 1.25x headroom = 5
      assert rec.max_turns == 5
      assert rec.max_tokens == 10_000
      assert rec.max_wall_ms == 18_750
    end
  end
end

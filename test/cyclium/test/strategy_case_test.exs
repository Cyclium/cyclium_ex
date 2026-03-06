defmodule Cyclium.Test.StrategyCaseTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.StrategyCase

  alias Cyclium.TestKit.SampleStrategy
  alias Cyclium.TestKit.InfiniteStrategy
  alias Cyclium.TestKit.AbortingStrategy

  @trigger %Cyclium.Trigger.Manual{requested_by: "test", reason: "test"}

  describe "build_test_episode/1" do
    test "returns a valid episode struct with defaults" do
      episode = build_test_episode()
      assert episode.actor_id == "test_actor"
      assert episode.status == :running
      assert episode.turns_used == 0
    end

    test "accepts overrides" do
      episode = build_test_episode(actor_id: "custom", turns_used: 5)
      assert episode.actor_id == "custom"
      assert episode.turns_used == 5
    end
  end

  describe "build_episode_ctx/1" do
    test "builds context map from episode" do
      episode = build_test_episode(actor_id: "my_actor")
      ctx = build_episode_ctx(episode)
      assert ctx.actor_id == "my_actor"
      assert ctx.turns_used == 0
      assert Map.has_key?(ctx, :budget)
    end
  end

  describe "assert_valid_init/3" do
    test "passes for valid strategy" do
      episode = build_test_episode()
      state = assert_valid_init(SampleStrategy, episode, @trigger)
      assert state["phase"] == "gather"
    end
  end

  describe "assert_valid_next_step/3" do
    test "passes for valid tool_call action" do
      episode = build_test_episode()
      {:ok, state} = SampleStrategy.init(episode, @trigger)
      ctx = build_episode_ctx(episode)

      action = assert_valid_next_step(SampleStrategy, state, ctx)
      assert {:tool_call, :test_tool, :fetch_data, _args} = action
    end

    test "rejects invalid action shapes" do
      assert_raise ArgumentError, ~r/invalid action shape/, fn ->
        Cyclium.Test.StrategyCase.validate_next_step_shape!({:invalid, "bad"})
      end
    end
  end

  describe "assert_valid_handle_result/4" do
    test "passes for {:ok, state} response" do
      episode = build_test_episode()
      {:ok, state} = SampleStrategy.init(episode, @trigger)
      step = build_test_step()

      assert_valid_handle_result(SampleStrategy, state, step, %{"result" => "data"})
    end
  end

  describe "assert_valid_converge/3" do
    test "passes for valid converge result" do
      episode = build_test_episode()
      {:ok, state} = SampleStrategy.init(episode, @trigger)
      ctx = build_episode_ctx(episode)

      # Advance to converge phase
      converge_state = %{state | "phase" => "converge"}
      assert_valid_converge(SampleStrategy, converge_state, ctx)
    end
  end

  describe "assert_strategy_terminates/4" do
    test "passes for a strategy that completes" do
      episode = build_test_episode()
      result = assert_strategy_terminates(SampleStrategy, episode, @trigger, max_steps: 20)
      assert {:ok, _state, step_count} = result
      assert step_count > 0
    end

    test "fails for an infinite strategy" do
      episode = build_test_episode()

      assert_raise ArgumentError, ~r/did not terminate within 5 steps/, fn ->
        assert_strategy_terminates(InfiniteStrategy, episode, @trigger, max_steps: 5)
      end
    end

    test "handles aborting strategy" do
      episode = build_test_episode()
      result = assert_strategy_terminates(AbortingStrategy, episode, @trigger)
      assert {:aborted, :test_abort_reason, _} = result
    end

    test "accepts custom step handler" do
      episode = build_test_episode()

      custom_handler = fn
        {:tool_call, _cap, _act, _args}, _state -> {:result, %{"custom" => true}}
        {:synthesize, _ctx}, _state -> {:result, %{"custom_synthesis" => true}}
        _action, _state -> :skip
      end

      result =
        assert_strategy_terminates(SampleStrategy, episode, @trigger,
          max_steps: 20,
          handle_step: custom_handler
        )

      assert {:ok, _state, _count} = result
    end
  end

  describe "validate_next_step_shape!/1" do
    test "accepts all valid shapes" do
      valid_actions = [
        :done,
        :converge,
        {:tool_call, :cap, :act, %{}},
        {:synthesize, %{prompt: "test"}},
        {:observe, %{data: "test"}},
        {:output, :email, %{to: "test"}},
        {:checkpoint, "phase_name"},
        {:approval, %{request: "approve"}},
        {:wait, %{ref: "ext-123"}}
      ]

      Enum.each(valid_actions, fn action ->
        assert Cyclium.Test.StrategyCase.validate_next_step_shape!(action) == action
      end)
    end

    test "rejects invalid shapes" do
      invalid_actions = [
        {:tool_call, "string_cap", :act, %{}},
        {:synthesize, "not_a_map"},
        {:checkpoint, :not_binary},
        {:unknown_action, %{}},
        nil,
        42
      ]

      Enum.each(invalid_actions, fn action ->
        assert_raise ArgumentError, fn ->
          Cyclium.Test.StrategyCase.validate_next_step_shape!(action)
        end
      end)
    end
  end
end

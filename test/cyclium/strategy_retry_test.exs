defmodule Cyclium.Strategy.RetryTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Retry

  defp make_step(kind), do: %{kind: kind}

  describe "check/3" do
    test "returns {:retry, state} when under max_attempts" do
      state = %{phase: :synthesizing}
      step = make_step(:synthesis)

      assert {:retry, new_state} = Retry.check(state, step, max_attempts: 3)
      assert new_state.__retries[:synthesis] == 1
      assert new_state.phase == :synthesizing
    end

    test "increments attempt count on successive retries" do
      state = %{}
      step = make_step(:synthesis)

      {:retry, state} = Retry.check(state, step, max_attempts: 3)
      assert state.__retries[:synthesis] == 1

      {:retry, state} = Retry.check(state, step, max_attempts: 3)
      assert state.__retries[:synthesis] == 2
    end

    test "returns {:give_up, count, state} when max_attempts reached" do
      state = %{__retries: %{synthesis: 2}}
      step = make_step(:synthesis)

      assert {:give_up, 3, new_state} = Retry.check(state, step, max_attempts: 3)
      # Counter is reset after give_up
      refute Map.has_key?(Map.get(new_state, :__retries, %{}), :synthesis)
    end

    test "defaults to max_attempts: 3" do
      state = %{}
      step = make_step(:tool_call)

      {:retry, state} = Retry.check(state, step)
      {:retry, state} = Retry.check(state, step)
      assert {:give_up, 3, _state} = Retry.check(state, step)
    end

    test "uses step.kind as default step_key" do
      state = %{}
      {:retry, state} = Retry.check(state, make_step(:synthesis))
      {:retry, state} = Retry.check(state, make_step(:tool_call))

      assert state.__retries[:synthesis] == 1
      assert state.__retries[:tool_call] == 1
    end

    test "supports custom step_key" do
      state = %{}
      step = make_step(:tool_call)

      {:retry, state} = Retry.check(state, step, step_key: {:tool, "weather.fetch"})
      assert state.__retries[{:tool, "weather.fetch"}] == 1
      refute Map.has_key?(state.__retries, :tool_call)
    end

    test "tracks separate retry counts per key" do
      state = %{}

      {:retry, state} = Retry.check(state, make_step(:synthesis), max_attempts: 2)
      {:retry, state} = Retry.check(state, make_step(:tool_call), max_attempts: 2)

      # synthesis gives up on next attempt
      assert {:give_up, 2, state} = Retry.check(state, make_step(:synthesis), max_attempts: 2)
      # tool_call still has one retry left
      assert {:give_up, 2, _state} = Retry.check(state, make_step(:tool_call), max_attempts: 2)
    end

    test "backoff_ms accepts a per-attempt function, called with the attempt number" do
      state = %{}
      step = make_step(:synthesis)
      # Return 0 to skip the sleep; record which attempt number was passed.
      fun = fn attempt ->
        Process.put(:last_backoff_attempt, attempt)
        0
      end

      {:retry, state} = Retry.check(state, step, max_attempts: 3, backoff_ms: fun)
      assert Process.get(:last_backoff_attempt) == 1

      {:retry, _state} = Retry.check(state, step, max_attempts: 3, backoff_ms: fun)
      assert Process.get(:last_backoff_attempt) == 2
    end

    test "preserves existing state keys" do
      state = %{phase: :gathering, results: [1, 2, 3]}
      step = make_step(:synthesis)

      {:retry, new_state} = Retry.check(state, step)
      assert new_state.phase == :gathering
      assert new_state.results == [1, 2, 3]
    end
  end

  describe "reset/2" do
    test "clears retry count for a specific key" do
      state = %{__retries: %{synthesis: 2, tool_call: 1}}

      new_state = Retry.reset(state, :synthesis)
      refute Map.has_key?(new_state.__retries, :synthesis)
      assert new_state.__retries[:tool_call] == 1
    end

    test "is a no-op when key doesn't exist" do
      state = %{__retries: %{tool_call: 1}}
      assert Retry.reset(state, :synthesis) == %{__retries: %{tool_call: 1}}
    end

    test "works when no __retries key exists" do
      state = %{phase: :done}
      new_state = Retry.reset(state, :synthesis)
      assert new_state.__retries == %{}
    end
  end

  describe "reset_all/1" do
    test "removes all retry tracking" do
      state = %{__retries: %{synthesis: 2, tool_call: 1}, phase: :done}

      new_state = Retry.reset_all(state)
      refute Map.has_key?(new_state, :__retries)
      assert new_state.phase == :done
    end

    test "is a no-op when no __retries key exists" do
      state = %{phase: :done}
      assert Retry.reset_all(state) == state
    end
  end
end

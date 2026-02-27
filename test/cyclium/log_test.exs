defmodule Cyclium.LogTest do
  use ExUnit.Case, async: true

  alias Cyclium.Log

  describe "set_context/1" do
    test "sets cyclium_ prefixed metadata on Logger" do
      Log.set_context(
        cyclium_actor_id: :test_actor,
        cyclium_episode_id: "ep-123",
        cyclium_expectation_id: :check_health
      )

      meta = Logger.metadata()
      assert meta[:cyclium_actor_id] == :test_actor
      assert meta[:cyclium_episode_id] == "ep-123"
      assert meta[:cyclium_expectation_id] == :check_health
    end

    test "ignores non-cyclium keys" do
      Log.set_context(
        cyclium_actor_id: :test,
        random_key: "should_be_ignored"
      )

      meta = Logger.metadata()
      assert meta[:cyclium_actor_id] == :test
      refute Keyword.has_key?(meta, :random_key)
    end

    test "supports workflow context keys" do
      Log.set_context(
        cyclium_workflow_id: "wf-1",
        cyclium_instance_id: "inst-1",
        cyclium_step_id: "step_a"
      )

      meta = Logger.metadata()
      assert meta[:cyclium_workflow_id] == "wf-1"
      assert meta[:cyclium_instance_id] == "inst-1"
      assert meta[:cyclium_step_id] == "step_a"
    end
  end
end

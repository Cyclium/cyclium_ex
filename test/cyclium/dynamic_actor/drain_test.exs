defmodule Cyclium.DynamicActor.DrainTest do
  use ExUnit.Case, async: true

  alias Cyclium.Actor.Server

  describe "enter_drain/1" do
    test "sets draining flag to true" do
      state = %{
        actor_id: :test,
        draining: false,
        timers: %{},
        debounce_timers: %{}
      }

      new_state = Server.enter_drain(state)
      assert new_state.draining == true
    end

    test "clears debounce timers" do
      state = %{
        actor_id: :test,
        draining: false,
        timers: %{},
        debounce_timers: %{some_key: make_ref()}
      }

      new_state = Server.enter_drain(state)
      assert new_state.debounce_timers == %{}
    end
  end
end

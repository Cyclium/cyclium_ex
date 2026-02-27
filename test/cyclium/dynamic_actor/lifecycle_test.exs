defmodule Cyclium.DynamicActor.LifecycleTest do
  use ExUnit.Case, async: true

  alias Cyclium.DynamicActor.Lifecycle

  describe "active_episode_count/1" do
    test "returns 0 for non-running actor" do
      assert Lifecycle.active_episode_count("nonexistent_actor") == 0
    end
  end

  describe "drain_and_stop/1" do
    test "returns error for non-running actor" do
      assert {:error, :not_running} = Lifecycle.drain_and_stop("nonexistent_actor")
    end
  end
end

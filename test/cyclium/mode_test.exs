defmodule Cyclium.ModeTest do
  use ExUnit.Case, async: false

  setup do
    # Start Mode GenServer fresh for each test
    Application.put_env(:cyclium, :mode, :full)
    start_supervised!(Cyclium.Mode)

    on_exit(fn ->
      Application.delete_env(:cyclium, :mode)
    end)

    :ok
  end

  describe "current/0" do
    test "returns the configured default mode" do
      assert Cyclium.Mode.current() == :full
    end

    test "reflects runtime changes" do
      Cyclium.Mode.set(:trigger_only)
      assert Cyclium.Mode.current() == :trigger_only
    end
  end

  describe "set/1" do
    test "switches to trigger_only" do
      assert :ok = Cyclium.Mode.set(:trigger_only)
      assert Cyclium.Mode.current() == :trigger_only
    end

    test "switches to disabled" do
      assert :ok = Cyclium.Mode.set(:disabled)
      assert Cyclium.Mode.current() == :disabled
    end

    test "switches back to full" do
      Cyclium.Mode.set(:trigger_only)
      Cyclium.Mode.set(:full)
      assert Cyclium.Mode.current() == :full
    end
  end

  describe "set_actor_override/2" do
    test "overrides mode for a specific actor" do
      Cyclium.Mode.set_actor_override(:client_health, :trigger_only)
      assert Cyclium.Mode.effective(:client_health) == :trigger_only
    end

    test "does not affect other actors" do
      Cyclium.Mode.set_actor_override(:client_health, :trigger_only)
      assert Cyclium.Mode.effective(:other_actor) == :full
    end

    test "override takes precedence over node mode" do
      Cyclium.Mode.set(:trigger_only)
      Cyclium.Mode.set_actor_override(:special_actor, :full)
      assert Cyclium.Mode.effective(:special_actor) == :full
      assert Cyclium.Mode.effective(:regular_actor) == :trigger_only
    end
  end

  describe "clear_actor_override/1" do
    test "falls back to node mode after clearing" do
      Cyclium.Mode.set_actor_override(:client_health, :trigger_only)
      Cyclium.Mode.clear_actor_override(:client_health)
      assert Cyclium.Mode.effective(:client_health) == :full
    end
  end

  describe "clear_all_overrides/0" do
    test "clears all per-actor overrides" do
      Cyclium.Mode.set_actor_override(:actor_a, :trigger_only)
      Cyclium.Mode.set_actor_override(:actor_b, :trigger_only)
      Cyclium.Mode.clear_all_overrides()
      assert Cyclium.Mode.overrides() == %{}
      assert Cyclium.Mode.effective(:actor_a) == :full
    end
  end

  describe "runner_for/1" do
    test "returns OTP runner in full mode" do
      assert Cyclium.Mode.runner_for(:any_actor) == Cyclium.Runner.OTP
    end

    test "returns Deferred runner in trigger_only mode" do
      Cyclium.Mode.set(:trigger_only)
      assert Cyclium.Mode.runner_for(:any_actor) == Cyclium.Runner.Deferred
    end

    test "respects per-actor override" do
      Cyclium.Mode.set_actor_override(:deferred_actor, :trigger_only)
      assert Cyclium.Mode.runner_for(:deferred_actor) == Cyclium.Runner.Deferred
      assert Cyclium.Mode.runner_for(:normal_actor) == Cyclium.Runner.OTP
    end

    test "accepts string actor_id" do
      Cyclium.Mode.set_actor_override(:client_health, :trigger_only)
      assert Cyclium.Mode.runner_for("client_health") == Cyclium.Runner.Deferred
    end
  end

  describe "default_runner/0" do
    test "returns OTP for full mode" do
      assert Cyclium.Mode.default_runner() == Cyclium.Runner.OTP
    end

    test "returns Deferred for trigger_only" do
      Cyclium.Mode.set(:trigger_only)
      assert Cyclium.Mode.default_runner() == Cyclium.Runner.Deferred
    end
  end

  describe "overrides/0" do
    test "returns empty map when no overrides" do
      assert Cyclium.Mode.overrides() == %{}
    end

    test "returns all active overrides" do
      Cyclium.Mode.set_actor_override(:a, :trigger_only)
      Cyclium.Mode.set_actor_override(:b, :full)
      assert Cyclium.Mode.overrides() == %{a: :trigger_only, b: :full}
    end
  end

  describe "status/0" do
    test "returns complete status map" do
      Cyclium.Mode.set_actor_override(:test_actor, :trigger_only)
      status = Cyclium.Mode.status()

      assert status.node_mode == :full
      assert status.overrides == %{test_actor: :trigger_only}
      assert is_binary(status.node_identity)
    end
  end
end

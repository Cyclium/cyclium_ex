defmodule Cyclium.Test.ActorCaseTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.ActorCase

  alias Cyclium.TestKit.SampleActor
  alias Cyclium.TestKit.MinimalActor

  describe "assert_valid_actor/1" do
    test "passes for a well-formed actor" do
      assert :ok = assert_valid_actor(SampleActor)
    end

    test "passes for a minimal actor" do
      assert :ok = assert_valid_actor(MinimalActor)
    end

    test "validates identifier" do
      assert SampleActor.identifier() == :test_kit_actor
      assert MinimalActor.identifier() == :minimal_actor
    end
  end

  describe "assert_strategies_defined/1" do
    test "passes when all expectations have strategies" do
      assert_strategies_defined(SampleActor)
    end

    test "passes for minimal actor" do
      assert_strategies_defined(MinimalActor)
    end
  end

  describe "assert_budgets_valid/1" do
    test "passes for valid budgets" do
      assert_budgets_valid(SampleActor)
    end

    test "passes for default budgets" do
      assert_budgets_valid(MinimalActor)
    end
  end

  describe "assert_spec_rev_set/1" do
    test "passes when spec_rev is declared" do
      assert_spec_rev_set(SampleActor)
    end

    test "fails when spec_rev is not set" do
      assert_raise ArgumentError, ~r/spec_rev/, fn ->
        assert_spec_rev_set(MinimalActor)
      end
    end
  end

  describe "validate_expectation!/3" do
    test "validates schedule triggers" do
      Cyclium.Test.ActorCase.validate_expectation!(
        SampleActor,
        :test,
        trigger: {:schedule, 60_000}
      )
    end

    test "validates event triggers" do
      Cyclium.Test.ActorCase.validate_expectation!(
        SampleActor,
        :test,
        trigger: {:event, "test.event"}
      )
    end

    test "validates multi-triggers" do
      Cyclium.Test.ActorCase.validate_expectation!(
        SampleActor,
        :test,
        trigger: [{:schedule, 60_000}, {:event, "test.event"}]
      )
    end

    test "rejects invalid trigger" do
      assert_raise ArgumentError, ~r/invalid trigger/, fn ->
        Cyclium.Test.ActorCase.validate_expectation!(
          SampleActor,
          :test,
          trigger: {:unknown, "bad"}
        )
      end
    end

    test "rejects invalid recovery_policy" do
      assert_raise ArgumentError, ~r/recovery_policy/, fn ->
        Cyclium.Test.ActorCase.validate_expectation!(
          SampleActor,
          :test,
          trigger: {:event, "test"},
          recovery_policy: :maybe
        )
      end
    end

    test "rejects out-of-range sample_rate" do
      assert_raise ArgumentError, ~r/sample_rate/, fn ->
        Cyclium.Test.ActorCase.validate_expectation!(
          SampleActor,
          :test,
          trigger: {:event, "test"},
          sample_rate: 1.5
        )
      end
    end
  end
end

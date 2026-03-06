defmodule Cyclium.Test.CheckpointMigrationTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.CheckpointMigration

  alias Cyclium.TestKit.SampleCheckpointV3
  alias Cyclium.TestKit.FragileCheckpoint

  describe "assert_migration_safe/2" do
    test "passes for a resilient schema with default generator" do
      assert_migration_safe(SampleCheckpointV3, from: 1, iterations: 50)
    end

    test "passes with custom generator" do
      assert_migration_safe(SampleCheckpointV3,
        from: 2,
        iterations: 30,
        generator: fn ->
          StreamData.map(
            StreamData.string(:alphanumeric),
            &%{"data" => &1}
          )
        end
      )
    end

    test "fails for a fragile schema missing required keys" do
      assert_raise ExUnit.AssertionError, ~r/missing_required_field/, fn ->
        assert_migration_safe(FragileCheckpoint,
          from: 1,
          iterations: 10
        )
      end
    end

    test "passes for fragile schema when generator provides required key" do
      assert_migration_safe(FragileCheckpoint,
        from: 1,
        iterations: 20,
        generator: fn ->
          StreamData.map(
            StreamData.string(:alphanumeric, min_length: 1),
            &%{"required_field" => &1}
          )
        end
      )
    end
  end

  describe "assert_migration/4" do
    test "asserts specific migration output" do
      assert_migration(SampleCheckpointV3, 1, %{"data" => "hello"}, %{
        "data" => "hello",
        "format" => "v3"
      })
    end
  end

  describe "assert_migration_idempotent/2" do
    test "current version state passes through unchanged" do
      state = %{"data" => "hello", "format" => "v3"}
      assert_migration_idempotent(SampleCheckpointV3, state)
    end
  end

  describe "default_state_generator/0" do
    test "generates maps with string keys" do
      states = Enum.take(Cyclium.Test.CheckpointMigration.default_state_generator(), 20)

      Enum.each(states, fn state ->
        assert is_map(state)

        Enum.each(state, fn {k, _v} ->
          assert is_binary(k), "Expected string key, got: #{inspect(k)}"
        end)
      end)
    end
  end
end

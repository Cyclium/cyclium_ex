defmodule Cyclium.CheckpointSchemaTest do
  use ExUnit.Case

  defmodule V3Schema do
    use Cyclium.CheckpointSchema, version: 3

    def migrate(1, state) do
      {:ok, Map.put(state, "format", "v2")}
    end

    def migrate(2, state) do
      {:ok, Map.put(state, "format", "v3")}
    end

    def migrate(3, state), do: {:ok, state}
    def migrate(_v, _state), do: {:error, :unsupported_version}
  end

  defmodule V1Schema do
    use Cyclium.CheckpointSchema, version: 1

    def migrate(1, state), do: {:ok, state}
    def migrate(_v, _state), do: {:error, :unsupported_version}
  end

  describe "__checkpoint_version__/0" do
    test "returns the declared version" do
      assert V3Schema.__checkpoint_version__() == 3
      assert V1Schema.__checkpoint_version__() == 1
    end
  end

  describe "migrate_to_current/2" do
    test "identity migration when already at current version" do
      state = %{"data" => "hello"}
      assert {:ok, ^state} = V3Schema.migrate_to_current(3, state)
    end

    test "chains through intermediate versions" do
      state = %{"data" => "hello"}
      assert {:ok, result} = V3Schema.migrate_to_current(1, state)
      assert result["format"] == "v3"
    end

    test "single-step migration" do
      state = %{"data" => "hello"}
      assert {:ok, result} = V3Schema.migrate_to_current(2, state)
      assert result["format"] == "v3"
    end

    test "returns error for unsupported version" do
      assert {:error, :unsupported_version} = V3Schema.migrate_to_current(0, %{})
    end

    test "returns error when version is ahead of current" do
      assert {:error, {:version_ahead, 5, 3}} = V3Schema.migrate_to_current(5, %{})
    end

    test "v1 schema identity migration" do
      state = %{"phase" => "collecting"}
      assert {:ok, ^state} = V1Schema.migrate_to_current(1, state)
    end
  end

  describe "json_plain?/1" do
    test "true for JSON-plain state (string keys, scalars, nested lists/maps)" do
      assert Cyclium.CheckpointSchema.json_plain?(%{
               "phase" => "collecting",
               "count" => 3,
               "done" => false,
               "items" => [%{"id" => "a"}, %{"id" => "b"}]
             })
    end

    test "true for empty map and primitives" do
      assert Cyclium.CheckpointSchema.json_plain?(%{})
      assert Cyclium.CheckpointSchema.json_plain?("hello")
      assert Cyclium.CheckpointSchema.json_plain?(42)
    end

    test "false for atom keys (they don't round-trip — become strings)" do
      refute Cyclium.CheckpointSchema.json_plain?(%{phase: "collecting"})
    end

    test "false for atom values (become strings on decode)" do
      refute Cyclium.CheckpointSchema.json_plain?(%{"phase" => :collecting})
    end

    test "false for tuples (not JSON-encodable at all)" do
      refute Cyclium.CheckpointSchema.json_plain?(%{"range" => {1, 2}})
    end

    test "false for a struct value" do
      refute Cyclium.CheckpointSchema.json_plain?(%{"at" => ~D[2026-08-24]})
    end
  end

  describe "assert_json_plain!/1" do
    test "returns :ok for JSON-plain state" do
      assert Cyclium.CheckpointSchema.assert_json_plain!(%{"phase" => "x"}) == :ok
    end

    test "raises with a shape-changed message when it encodes but doesn't round-trip" do
      assert_raise ArgumentError, ~r/does not round-trip/, fn ->
        Cyclium.CheckpointSchema.assert_json_plain!(%{phase: "collecting"})
      end
    end

    test "raises with a not-encodable message for tuples/structs" do
      assert_raise ArgumentError, ~r/not JSON-encodable/, fn ->
        Cyclium.CheckpointSchema.assert_json_plain!(%{"range" => {1, 2}})
      end
    end
  end

  describe "resolve/2" do
    setup do
      on_exit(fn ->
        Application.delete_env(:cyclium, :checkpoint_schemas)
        :persistent_term.erase({:cyclium_expectation_checkpoint_schema, :res_actor, :res_exp})
      end)

      :ok
    end

    test "returns nil when nothing is registered" do
      assert Cyclium.CheckpointSchema.resolve("res_actor", "res_exp") == nil
    end

    test "resolves from config by {actor_id, expectation_id} key" do
      Application.put_env(:cyclium, :checkpoint_schemas, %{
        {"res_actor", "res_exp"} => V3Schema
      })

      assert Cyclium.CheckpointSchema.resolve("res_actor", "res_exp") == V3Schema
    end

    test "falls back to actor-level config key" do
      Application.put_env(:cyclium, :checkpoint_schemas, %{"res_actor" => V1Schema})

      assert Cyclium.CheckpointSchema.resolve("res_actor", "res_exp") == V1Schema
    end

    test "resolves expectation-declared schema from persistent_term" do
      :persistent_term.put(
        {:cyclium_expectation_checkpoint_schema, :res_actor, :res_exp},
        V3Schema
      )

      # String ids (as stored on DB-loaded episodes) resolve to the atom-keyed
      # registration
      assert Cyclium.CheckpointSchema.resolve("res_actor", "res_exp") == V3Schema
      # Atom ids resolve too
      assert Cyclium.CheckpointSchema.resolve(:res_actor, :res_exp) == V3Schema
    end

    test "config override wins over expectation-declared schema" do
      :persistent_term.put(
        {:cyclium_expectation_checkpoint_schema, :res_actor, :res_exp},
        V3Schema
      )

      Application.put_env(:cyclium, :checkpoint_schemas, %{
        {"res_actor", "res_exp"} => V1Schema
      })

      assert Cyclium.CheckpointSchema.resolve("res_actor", "res_exp") == V1Schema
    end

    test "ids with no existing atom resolve to nil instead of raising" do
      assert Cyclium.CheckpointSchema.resolve(
               "no_such_actor_atom_xyz",
               "no_such_exp_atom_xyz"
             ) == nil
    end
  end
end

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
end

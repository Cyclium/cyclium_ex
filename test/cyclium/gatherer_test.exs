defmodule Cyclium.GathererTest do
  use ExUnit.Case, async: true

  alias Cyclium.Gatherer

  defmodule TestGatherer do
    @behaviour Cyclium.Gatherer

    @impl true
    def gather(%{"key" => val}, _opts) do
      {:ok, %{result: val}}
    end

    def gather(_payload, _opts) do
      {:error, :missing_key}
    end
  end

  describe "resolve/1" do
    test "returns nil when no registry configured" do
      assert Gatherer.resolve("nonexistent") == nil
    end

    test "resolves registered gatherer" do
      prev = Application.get_env(:cyclium, :gatherer_registry)
      Application.put_env(:cyclium, :gatherer_registry, %{"test" => TestGatherer})

      try do
        assert Gatherer.resolve("test") == TestGatherer
        assert Gatherer.resolve("unknown") == nil
      after
        if prev,
          do: Application.put_env(:cyclium, :gatherer_registry, prev),
          else: Application.delete_env(:cyclium, :gatherer_registry)
      end
    end
  end

  describe "TestGatherer" do
    test "gathers data from payload" do
      assert {:ok, %{result: "hello"}} = TestGatherer.gather(%{"key" => "hello"}, %{})
    end

    test "returns error for missing key" do
      assert {:error, :missing_key} = TestGatherer.gather(%{}, %{})
    end
  end
end

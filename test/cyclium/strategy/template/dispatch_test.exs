defmodule Cyclium.Strategy.Template.DispatchTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.Dispatch

  describe "next_step/2" do
    test "always converges — no step loop" do
      assert Dispatch.next_step(%{dispatched: 0}, %{}) == :converge
      assert Dispatch.next_step(%{dispatched: 5}, %{}) == :converge
    end
  end

  describe "handle_result/3" do
    test "is a passthrough — all work is done in init" do
      state = %{dispatched: 3}
      assert {:ok, ^state} = Dispatch.handle_result(state, %{}, {:ok, %{}})
      assert {:ok, ^state} = Dispatch.handle_result(state, %{}, {:error, :whatever})
    end
  end

  describe "converge/2" do
    test "produces ConvergeResult with dispatch count" do
      {:ok, result} = Dispatch.converge(%{dispatched: 5}, %{})

      assert result.classification == %{"primary" => "dispatch", "severity" => "low"}
      assert result.confidence == 1.0
      assert result.summary == "Dispatched 5 events"
      assert result.findings == []
      assert result.outputs == []
    end

    test "handles zero dispatched" do
      {:ok, result} = Dispatch.converge(%{dispatched: 0}, %{})
      assert result.summary == "Dispatched 0 events"
    end
  end
end

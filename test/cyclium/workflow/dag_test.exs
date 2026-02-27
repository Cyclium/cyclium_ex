defmodule Cyclium.Workflow.DAGTest do
  use ExUnit.Case, async: true

  alias Cyclium.Workflow.DAG

  describe "validate!/1" do
    test "valid DAG with no dependencies" do
      adj = %{a: [], b: [], c: []}
      assert DAG.validate!(adj) == :ok
    end

    test "valid DAG with linear dependencies" do
      adj = %{a: [], b: [:a], c: [:b]}
      assert DAG.validate!(adj) == :ok
    end

    test "valid DAG with diamond dependencies" do
      adj = %{a: [], b: [:a], c: [:a], d: [:b, :c]}
      assert DAG.validate!(adj) == :ok
    end

    test "detects simple cycle" do
      adj = %{a: [:b], b: [:a]}
      assert {:error, {:cycle, _node}} = DAG.validate!(adj)
    end

    test "detects three-node cycle" do
      adj = %{a: [:c], b: [:a], c: [:b]}
      assert {:error, {:cycle, _node}} = DAG.validate!(adj)
    end

    test "detects self-referencing node" do
      adj = %{a: [:a]}
      assert {:error, {:cycle, :a}} = DAG.validate!(adj)
    end

    test "empty adjacency is valid" do
      assert DAG.validate!(%{}) == :ok
    end
  end

  describe "topo_sort/2" do
    test "returns topological order" do
      adj = %{a: [], b: [:a], c: [:b]}
      {:ok, order} = DAG.topo_sort(adj, [:a, :b, :c])

      a_idx = Enum.find_index(order, &(&1 == :a))
      b_idx = Enum.find_index(order, &(&1 == :b))
      c_idx = Enum.find_index(order, &(&1 == :c))

      assert a_idx < b_idx
      assert b_idx < c_idx
    end

    test "returns error for cycle" do
      adj = %{a: [:b], b: [:a]}
      assert {:error, _} = DAG.topo_sort(adj, [:a, :b])
    end
  end
end

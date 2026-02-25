defmodule Cyclium.BatchTest do
  use ExUnit.Case

  alias Cyclium.Batch

  describe "chunk/2" do
    test "splits items into fixed-size groups" do
      items = [1, 2, 3, 4, 5, 6, 7]
      groups = Batch.chunk(items, 3)

      assert groups == [{0, [1, 2, 3]}, {1, [4, 5, 6]}, {2, [7]}]
    end

    test "single chunk when size >= items" do
      assert Batch.chunk([1, 2], 5) == [{0, [1, 2]}]
    end

    test "empty list returns empty" do
      assert Batch.chunk([], 3) == []
    end
  end

  describe "group_by/2" do
    test "groups items by key function" do
      items = [
        %{base: "widget", variant: "red"},
        %{base: "widget", variant: "blue"},
        %{base: "gadget", variant: "small"}
      ]

      groups = Batch.group_by(items, & &1.base)

      assert length(groups) == 2
      assert {"widget", widget_items} = Enum.find(groups, fn {k, _} -> k == "widget" end)
      assert length(widget_items) == 2
      assert {"gadget", gadget_items} = Enum.find(groups, fn {k, _} -> k == "gadget" end)
      assert length(gadget_items) == 1
    end
  end

  describe "init/1" do
    test "initializes with groups at index 0" do
      batch = Batch.init([{:a, [1, 2]}, {:b, [3, 4]}])

      assert batch.current_index == 0
      assert batch.results == []
      assert length(batch.groups) == 2
    end
  end

  describe "current_group/1" do
    test "returns first group initially" do
      batch = Batch.init([{:a, [1, 2]}, {:b, [3, 4]}])

      assert {:a, [1, 2]} = Batch.current_group(batch)
    end

    test "returns nil when all groups processed" do
      batch = Batch.init([{:a, [1]}])
      batch = Batch.advance(batch, "result_a")

      assert Batch.current_group(batch) == nil
    end
  end

  describe "advance/2" do
    test "moves to next group and stores result" do
      batch =
        Batch.init([{:a, [1]}, {:b, [2]}, {:c, [3]}])
        |> Batch.advance("result_a")

      assert batch.current_index == 1
      assert batch.results == ["result_a"]
      assert {:b, [2]} = Batch.current_group(batch)
    end

    test "accumulates results across advances" do
      batch =
        Batch.init([{:a, [1]}, {:b, [2]}])
        |> Batch.advance("r1")
        |> Batch.advance("r2")

      assert batch.results == ["r1", "r2"]
    end
  end

  describe "done?/1" do
    test "false when groups remain" do
      batch = Batch.init([{:a, [1]}, {:b, [2]}])
      refute Batch.done?(batch)
    end

    test "true when all groups processed" do
      batch =
        Batch.init([{:a, [1]}])
        |> Batch.advance("done")

      assert Batch.done?(batch)
    end

    test "true for empty batch" do
      assert Batch.done?(Batch.init([]))
    end
  end

  describe "group_count/1 and processed_count/1" do
    test "tracks progress" do
      batch = Batch.init([{:a, [1]}, {:b, [2]}, {:c, [3]}])

      assert Batch.group_count(batch) == 3
      assert Batch.processed_count(batch) == 0

      batch = Batch.advance(batch, "r1")
      assert Batch.processed_count(batch) == 1

      batch = Batch.advance(batch, "r2")
      assert Batch.processed_count(batch) == 2
    end
  end

  describe "full workflow" do
    test "chunk → init → process all → done" do
      items = Enum.to_list(1..10)
      groups = Batch.chunk(items, 3)
      batch = Batch.init(groups)

      assert Batch.group_count(batch) == 4
      refute Batch.done?(batch)

      # Process all groups
      batch =
        Enum.reduce(0..3, batch, fn _i, acc ->
          {_key, chunk} = Batch.current_group(acc)
          Batch.advance(acc, Enum.sum(chunk))
        end)

      assert Batch.done?(batch)
      assert batch.results == [6, 15, 24, 10]
    end
  end
end

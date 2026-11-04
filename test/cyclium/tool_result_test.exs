defmodule Cyclium.ToolResultTest do
  use ExUnit.Case, async: true

  alias Cyclium.ToolResult

  @columnar %{"tool_result_format" => "columnar"}

  defp decode!(text), do: Jason.decode!(text)

  describe "default format" do
    test "renders compact JSON" do
      assert ToolResult.render([%{a: 1}, %{a: 2}], %{}) == ~s([{"a":1},{"a":2}])
      assert ToolResult.render(%{"k" => [1, 2]}, nil) == ~s({"k":[1,2]})
    end

    test "inspects a term JSON can't encode" do
      assert ToolResult.render({:tuple, 1}, %{}) =~ "{:tuple, 1}"
    end
  end

  describe "columnar" do
    test "a list of maps becomes sorted columns and rows, with null for a missing key" do
      rows = [
        %{"b" => 1, "a" => "x", "c" => true, "d" => 2, "e" => 3},
        %{"a" => "y", "b" => 2, "c" => nil, "e" => 4}
      ]

      assert decode!(ToolResult.render(rows, @columnar)) == %{
               "columns" => ["a", "b", "c", "d", "e"],
               "rows" => [["x", 1, true, 2, 3], ["y", 2, nil, nil, 4]]
             }
    end

    test "atom keys render like string keys" do
      assert decode!(ToolResult.render([%{id: 1, name: "a"}], %{tool_result_format: :columnar})) ==
               %{"columns" => ["id", "name"], "rows" => [[1, "a"]]}
    end

    test "a nested map or list stays a JSON value in its cell" do
      rows = [%{"id" => 1, "parts" => [%{"n" => 1}], "meta" => %{"k" => "v"}}]

      assert decode!(ToolResult.render(rows, @columnar)) == %{
               "columns" => ["id", "meta", "parts"],
               "rows" => [[1, %{"k" => "v"}, [%{"n" => 1}]]]
             }
    end

    test "a list that is a value of a top-level map is rendered columnar beside the other fields" do
      result = %{"count" => 2, "lines" => [%{"n" => 1}, %{"n" => 2}], "note" => "x"}

      assert decode!(ToolResult.render(result, @columnar)) == %{
               "count" => 2,
               "lines" => %{"columns" => ["n"], "rows" => [[1], [2]]},
               "note" => "x"
             }
    end

    test "tool_result_columnar_nested: false leaves a wrapped list as it was" do
      config = Map.put(@columnar, "tool_result_columnar_nested", false)
      result = %{"lines" => [%{"n" => 1}]}

      assert decode!(ToolResult.render(result, config)) == result
    end

    test "a list deeper than one level stays as it was" do
      result = %{"outer" => %{"lines" => [%{"n" => 1}]}}

      assert decode!(ToolResult.render(result, @columnar)) == result
    end

    test "a list wider than tool_result_columns_max stays compact JSON" do
      wide = for i <- 1..31, into: %{}, do: {"c#{i}", i}

      assert decode!(ToolResult.render([wide], @columnar)) == [wide]

      assert %{"columns" => columns} =
               decode!(
                 ToolResult.render([wide], Map.put(@columnar, "tool_result_columns_max", 40))
               )

      assert length(columns) == 31
    end

    test "a list with a row holding less than 80% of the columns stays compact JSON" do
      full = for i <- 1..10, into: %{}, do: {"c#{i}", i}
      sparse = Map.take(full, ["c1", "c2", "c3", "c4", "c5", "c6", "c7"])

      assert decode!(ToolResult.render([full, sparse], @columnar)) == [full, sparse]

      eight = Map.take(full, ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"])
      assert %{"columns" => _} = decode!(ToolResult.render([full, eight], @columnar))
    end

    test "a list with anything but maps in it, an empty list, and a scalar stay compact JSON" do
      assert ToolResult.render([1, 2], @columnar) == "[1,2]"
      assert ToolResult.render([%{"a" => 1}, "x"], @columnar) == ~s([{"a":1},"x"])
      assert ToolResult.render([], @columnar) == "[]"
      assert ToolResult.render("text", @columnar) == ~s("text")
      assert ToolResult.render(%{"a" => 1}, @columnar) == ~s({"a":1})
    end

    test "a row with a non-atom, non-string key keeps the list compact" do
      rows = [%{1 => "a"}, %{2 => "b"}]
      assert ToolResult.render(rows, @columnar) =~ ~s("1":"a")
    end

    test "settings read string or atom keys and ignore bad values" do
      assert ToolResult.format(%{"tool_result_format" => "csv"}) == "json"
      assert ToolResult.format(%{tool_result_format: "columnar"}) == "columnar"
      assert ToolResult.format(nil) == "json"
      assert ToolResult.columns_max(%{"tool_result_columns_max" => 0}) == 30
      assert ToolResult.columns_max(%{tool_result_columns_max: 12}) == 12
      assert ToolResult.columnar_nested?(%{}) == true
      assert ToolResult.columnar_nested?(%{tool_result_columnar_nested: false}) == false
    end
  end
end

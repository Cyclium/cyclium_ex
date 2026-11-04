defmodule Cyclium.ToolResult do
  @moduledoc """
  Renders a tool's result as the text the model reads.

  The default is compact JSON. With `strategy_config: %{tool_result_format:
  "columnar"}`, a list of maps is rendered as one `columns` list and a `rows`
  list of lists instead of a map per row, which is still JSON and costs about
  half the tokens of compact JSON on a table of any size:

      {"columns":["id","name"],"rows":[[1,"a"],[2,"b"]]}

  The columns are the sorted union of every row's keys. A key a row lacks and
  a null value are both `null`. A nested map or list stays a JSON value in its
  cell. The list may be the whole result or a value of a top-level map
  (`tool_result_columnar_nested`, on by default), which keeps scalar fields
  beside it as they are.

  A list stays compact JSON when it would make more than
  `tool_result_columns_max` columns (default 30), or when some row holds less
  than 80% of the columns; a wide or ragged table reads worse as rows than as
  maps. A list with anything but maps in it, a map with no such list in it, and
  any scalar are compact JSON too.

  A host that shows a result as the model saw it can call `render/2` with the
  actor's strategy config.
  """

  @default_columns_max 30
  @min_fill 0.8

  @doc """
  The text the model reads for `data`, under `strategy_config`'s
  `tool_result_format`, `tool_result_columns_max` and
  `tool_result_columnar_nested` (string or atom keys).
  """
  @spec render(term(), map() | nil) :: String.t()
  def render(data, strategy_config) do
    data
    |> shape(strategy_config)
    |> encode(data)
  end

  @doc """
  `"columnar"` or `"json"`, from `tool_result_format`; `"json"` unless set to
  `"columnar"` (or `:columnar`).
  """
  @spec format(map() | nil) :: String.t()
  def format(config) do
    case setting(config, "tool_result_format") do
      v when v in ["columnar", :columnar] -> "columnar"
      _ -> "json"
    end
  end

  @doc """
  The most columns a list is rendered columnar with, from
  `tool_result_columns_max` (a positive integer); #{@default_columns_max} unless set.
  """
  @spec columns_max(map() | nil) :: pos_integer()
  def columns_max(config) do
    case setting(config, "tool_result_columns_max") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_columns_max
    end
  end

  @doc """
  Whether a list of maps one level down, as a value of a top-level map, is
  rendered columnar too, from `tool_result_columnar_nested`; true unless false.
  """
  @spec columnar_nested?(map() | nil) :: boolean()
  def columnar_nested?(config), do: setting(config, "tool_result_columnar_nested") != false

  defp setting(%{} = config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, String.to_atom(key))
    end
  end

  defp setting(_config, _key), do: nil

  # The term to encode: `data` itself, or `data` with its tables columnar.
  defp shape(data, config) do
    if format(config) == "columnar",
      do: columnar(data, columns_max(config), columnar_nested?(config)),
      else: data
  end

  defp columnar(list, max, _nested) when is_list(list), do: table_or(list, list, max)

  defp columnar(%{__struct__: _} = struct, _max, _nested), do: struct

  defp columnar(%{} = map, max, true) do
    Map.new(map, fn
      {key, list} when is_list(list) -> {key, table_or(list, list, max)}
      pair -> pair
    end)
  end

  defp columnar(other, _max, _nested), do: other

  defp table_or(list, fallback, max) do
    case table(list, max) do
      {:ok, table} -> table
      :error -> fallback
    end
  end

  # `{:ok, %{"columns" => ..., "rows" => ...}}` for a list of maps with atom or
  # string keys that fits the width and fill rules, else :error.
  defp table([_ | _] = rows, max) do
    with {:ok, rows} <- string_keyed(rows),
         columns = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort(),
         true <- length(columns) <= max and filled?(rows, length(columns)) do
      {:ok,
       %{
         "columns" => columns,
         "rows" => Enum.map(rows, fn row -> Enum.map(columns, &Map.get(row, &1)) end)
       }}
    else
      _ -> :error
    end
  end

  defp table(_rows, _max), do: :error

  defp string_keyed(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{__struct__: _}, _acc ->
        {:halt, :error}

      %{} = row, {:ok, acc} ->
        if Enum.all?(Map.keys(row), &(is_binary(&1) or is_atom(&1))),
          do: {:cont, {:ok, [Map.new(row, fn {k, v} -> {to_string(k), v} end) | acc]}},
          else: {:halt, :error}

      _row, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp filled?(rows, column_count),
    do: Enum.all?(rows, &(map_size(&1) >= @min_fill * column_count))

  # Compact JSON: every later call of the episode resends each result, and the
  # whitespace of pretty-printing is paid for on each of them. A term JSON
  # can't encode is inspected instead.
  defp encode(term, original) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> inspect(original, limit: 500)
    end
  end
end

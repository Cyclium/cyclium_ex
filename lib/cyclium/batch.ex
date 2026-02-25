defmodule Cyclium.Batch do
  @moduledoc """
  Helpers for strategies that process data in grouped batches.

  Strategies remain in full control of the episode loop — Batch provides
  a lightweight struct for chunking data, tracking progress through groups,
  and collecting results. No new step types are introduced; strategies
  continue using `:tool_call` and `:synthesize` as normal.

  ## Usage

      # In strategy init — load items, group them, initialize batch
      items = load_all_items(product_id)
      batch = Cyclium.Batch.init(Cyclium.Batch.group_by(items, &base_item_id/1))

      # In next_step — drive the loop
      case Cyclium.Batch.current_group(state.batch) do
        nil -> :converge
        {group_key, items} -> {:synthesize, build_prompt(group_key, items)}
      end

      # In handle_result — advance to next group
      batch = Cyclium.Batch.advance(state.batch, parsed_result)
      {:ok, %{state | batch: batch}}
  """

  @type t :: %__MODULE__{
          groups: [{term(), [term()]}],
          current_index: non_neg_integer(),
          results: [term()]
        }

  defstruct groups: [],
            current_index: 0,
            results: []

  @doc """
  Initialize batch state from a list of `{group_key, items}` tuples.
  """
  @spec init([{term(), [term()]}]) :: t()
  def init(groups) when is_list(groups) do
    %__MODULE__{groups: groups, current_index: 0, results: []}
  end

  @doc """
  Get the current group to process.

  Returns `{group_key, items}` or `nil` when all groups are done.
  """
  @spec current_group(t()) :: {term(), [term()]} | nil
  def current_group(%__MODULE__{groups: groups, current_index: idx}) do
    Enum.at(groups, idx)
  end

  @doc """
  Advance to the next group, storing the result from the current one.
  """
  @spec advance(t(), term()) :: t()
  def advance(%__MODULE__{} = batch, result) do
    %{batch | current_index: batch.current_index + 1, results: batch.results ++ [result]}
  end

  @doc """
  Check if all groups have been processed.
  """
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{groups: groups, current_index: idx}) do
    idx >= length(groups)
  end

  @doc """
  Total number of groups.
  """
  @spec group_count(t()) :: non_neg_integer()
  def group_count(%__MODULE__{groups: groups}), do: length(groups)

  @doc """
  Number of groups already processed.
  """
  @spec processed_count(t()) :: non_neg_integer()
  def processed_count(%__MODULE__{results: results}), do: length(results)

  @doc """
  Chunk a flat list into groups of `size`.

  Returns `{index, items}` tuples suitable for `init/1`.
  """
  @spec chunk([term()], pos_integer()) :: [{non_neg_integer(), [term()]}]
  def chunk(items, size) when is_list(items) and is_integer(size) and size > 0 do
    items
    |> Enum.chunk_every(size)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} -> {idx, chunk} end)
  end

  @doc """
  Group items by a key function.

  Returns `{group_key, items}` tuples suitable for `init/1`.
  """
  @spec group_by([term()], (term() -> term())) :: [{term(), [term()]}]
  def group_by(items, key_fn) when is_list(items) and is_function(key_fn, 1) do
    items
    |> Enum.group_by(key_fn)
    |> Enum.to_list()
  end
end

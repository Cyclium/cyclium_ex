defmodule Cyclium.AtomGuard do
  @moduledoc """
  Bounded string-to-atom conversion for data sourced from outside the codebase
  (DB-defined dynamic actor/workflow definitions, persisted workflow results,
  and LLM-produced tool/output names).

  Atoms are never garbage-collected and the BEAM atom table is bounded
  (`:erlang.system_info(:atom_limit)`, ~1M by default). Converting
  high-cardinality external strings with `String.to_atom/1` — actor ids,
  expectation/step ids, subject keys, JSON keys, LLM-chosen tool names — leaks
  atoms permanently and can crash every node in the cluster with
  `system_limit`.

  `intern!/1` is a drop-in replacement for `String.to_atom/1` that:

    * returns an **existing** atom without minting (so reloading the same
      definition, or any value that matches a compiled atom, never grows the
      table), and
    * mints a new atom only while the atom table has headroom; once usage
      crosses the configured threshold it raises `Cyclium.AtomGuard.LimitError`.

  The net effect: an abusive or runaway set of dynamic definitions fails to
  load (a localized, catchable error) instead of taking down the node.

  ## Configuration

      # Refuse to mint new atoms once the atom table is this full (0.0–1.0).
      # Default: 0.8
      config :cyclium, :atom_guard_max_usage, 0.8
  """

  defmodule LimitError do
    @moduledoc "Raised when the atom table is too full to safely mint a new atom."
    defexception [:message]
  end

  @default_max_usage 0.8

  @doc """
  Convert `value` to an atom, bounded by atom-table headroom.

    * Atoms (and `nil`) pass through unchanged.
    * Binaries that already correspond to an existing atom are returned without
      minting — no table growth.
    * A genuinely new binary is minted only while atom-table usage is below the
      configured threshold; past it, raises `LimitError`.
    * Other terms are stringified first.
  """
  @spec intern!(term()) :: atom()
  def intern!(value) when is_atom(value), do: value

  def intern!(value) when is_binary(value) do
    case existing_atom(value) do
      {:ok, atom} ->
        atom

      :error ->
        ensure_headroom!(value)
        String.to_atom(value)
    end
  end

  def intern!(value), do: value |> to_string() |> intern!()

  @doc """
  Returns `{:ok, atom}` if `string` already corresponds to an atom, otherwise
  `:error`. Never mints a new atom.
  """
  @spec existing_atom(String.t()) :: {:ok, atom()} | :error
  def existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Returns `key` as an existing atom when one exists, otherwise the string
  unchanged. For JSON decoders (`Jason.decode!(json, keys: &AtomGuard.key/1)`):
  the keys the framework reads are compile-time atoms, so they come back as
  atoms, while unknown keys stay strings and never grow the atom table.
  """
  @spec key(binary()) :: atom() | binary()
  def key(string) when is_binary(string) do
    case existing_atom(string) do
      {:ok, atom} -> atom
      :error -> string
    end
  end

  @doc "Current atom-table usage as `%{count: n, limit: n, usage: 0.0..1.0}`."
  @spec usage() :: %{count: non_neg_integer(), limit: pos_integer(), usage: float()}
  def usage do
    count = :erlang.system_info(:atom_count)
    limit = :erlang.system_info(:atom_limit)
    %{count: count, limit: limit, usage: count / limit}
  end

  defp ensure_headroom!(value) do
    %{count: count, limit: limit} = usage()

    if count / limit >= max_usage() do
      :telemetry.execute(
        [:cyclium, :atom_guard, :refused],
        %{count: 1, atom_count: count, atom_limit: limit},
        %{value: value}
      )

      raise LimitError,
            "refused to intern #{inspect(value)}: atom table at #{count}/#{limit} " <>
              "(>= #{max_usage()} of limit). A dynamic definition or external input is " <>
              "creating too many distinct identifiers. Reduce identifier cardinality, " <>
              "reuse ids across reloads, or raise :atom_guard_max_usage."
    end
  end

  defp max_usage do
    Application.get_env(:cyclium, :atom_guard_max_usage, @default_max_usage)
  end
end

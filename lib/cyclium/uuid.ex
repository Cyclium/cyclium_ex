defmodule Cyclium.UUID do
  @moduledoc """
  The Ecto type of every cyclium id column: a UUID string in Elixir, sent to the
  database in a form its adapter can always read.

  `:binary_id` is not enough on SQL Server. The Tds adapter dumps a UUID to its
  16 raw bytes, then sends any binary parameter that `String.printable?/1`
  accepts as an `nvarchar`. About one random UUID in 46,000 is printable, and
  SQL Server cannot convert those 16 characters to a `uniqueidentifier`, so the
  insert or query fails with error 8169 ("Conversion failed when converting
  from a character string to uniqueidentifier"). On SQL Server this type sends
  the bytes as a typed `uniqueidentifier` parameter instead. On every other
  adapter it reads and writes what `:binary_id` does.

  The type reports `:uuid`, not `:binary_id`, so that primary keys are generated
  by `autogenerate/0` and pass through `dump/1`. A `:binary_id` key is generated
  by the adapter as raw bytes and reaches the driver with no dump step.

  A host's own schema over a cyclium table, or over any UUID column on SQL
  Server, should type its ids with this module too. The wire format follows the
  adapter of `config :cyclium, :repo`.
  """

  use Ecto.Type

  @impl true
  def type, do: :uuid

  @impl true
  def cast(value), do: Ecto.UUID.cast(value)

  @impl true
  def dump(value) do
    adapter = adapter()

    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, raw} <- raw_codec(adapter).dump(uuid) do
      {:ok, parameter(adapter, raw)}
    end
  end

  @impl true
  def load(<<_::128>> = raw), do: raw_codec(adapter()).load(raw)
  def load(value), do: Ecto.UUID.cast(value)

  @impl true
  @spec autogenerate() :: String.t()
  def autogenerate, do: Ecto.UUID.generate()

  @spec adapter() :: module() | nil
  defp adapter do
    repo = Application.get_env(:cyclium, :repo)
    if repo && function_exported?(repo, :__adapter__, 0), do: repo.__adapter__()
  end

  # The type the adapter itself converts `:binary_id` raw bytes with. Tds stores
  # a uniqueidentifier's first three groups little-endian, so its bytes are not
  # `Ecto.UUID`'s.
  @spec raw_codec(module() | nil) :: module()
  defp raw_codec(nil), do: Ecto.UUID

  defp raw_codec(adapter) do
    :binary_id
    |> adapter.loaders(:binary_id)
    |> Enum.find(Ecto.UUID, &(is_atom(&1) and &1 != :binary_id))
  end

  # A parameter with a type skips the Tds adapter's printable-string guess.
  @spec parameter(module() | nil, binary()) :: term()
  defp parameter(Ecto.Adapters.Tds, raw), do: struct(Tds.Parameter, value: raw, type: :uuid)
  defp parameter(_adapter, raw), do: raw
end

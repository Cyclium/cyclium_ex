defmodule Cyclium.Migrations do
  @moduledoc """
  Migration dispatcher. Consumer apps create thin wrappers that delegate here.

  ## Example

      defmodule MyApp.Repo.Migrations.CycliumV1 do
        use Ecto.Migration
        def up, do: Cyclium.Migrations.up(version: 1)
        def down, do: Cyclium.Migrations.down(version: 1)
      end

  For a fresh install, run every version in order — use `versions/0` so the list
  stays correct as new versions ship:

      def up, do: Enum.each(Cyclium.Migrations.versions(), &Cyclium.Migrations.up(version: &1))
  """

  @versions %{
    1 => Cyclium.Migrations.V1,
    2 => Cyclium.Migrations.V2,
    3 => Cyclium.Migrations.V3,
    4 => Cyclium.Migrations.V4,
    5 => Cyclium.Migrations.V5,
    6 => Cyclium.Migrations.V6,
    7 => Cyclium.Migrations.V7,
    8 => Cyclium.Migrations.V8,
    9 => Cyclium.Migrations.V9,
    10 => Cyclium.Migrations.V10,
    11 => Cyclium.Migrations.V11,
    12 => Cyclium.Migrations.V12,
    13 => Cyclium.Migrations.V13,
    14 => Cyclium.Migrations.V14,
    15 => Cyclium.Migrations.V15,
    16 => Cyclium.Migrations.V16,
    17 => Cyclium.Migrations.V17,
    18 => Cyclium.Migrations.V18,
    19 => Cyclium.Migrations.V19,
    20 => Cyclium.Migrations.V20,
    21 => Cyclium.Migrations.V21,
    22 => Cyclium.Migrations.V22,
    23 => Cyclium.Migrations.V23,
    24 => Cyclium.Migrations.V24,
    25 => Cyclium.Migrations.V25,
    26 => Cyclium.Migrations.V26
  }

  @doc "All known migration versions, ascending. Use to run every version in order."
  def versions, do: @versions |> Map.keys() |> Enum.sort()

  def up(opts) do
    version = Keyword.fetch!(opts, :version)

    case Map.fetch(@versions, version) do
      {:ok, module} -> module.up()
      :error -> raise "Unknown Cyclium migration version: #{version}"
    end
  end

  def down(opts) do
    version = Keyword.fetch!(opts, :version)

    case Map.fetch(@versions, version) do
      {:ok, module} -> module.down()
      :error -> raise "Unknown Cyclium migration version: #{version}"
    end
  end
end

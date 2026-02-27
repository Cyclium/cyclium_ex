defmodule Cyclium.Migrations do
  @moduledoc """
  Migration dispatcher. Consumer apps create thin wrappers that delegate here.

  ## Example

      defmodule MyApp.Repo.Migrations.CycliumV1 do
        use Ecto.Migration
        def up, do: Cyclium.Migrations.up(version: 1)
        def down, do: Cyclium.Migrations.down(version: 1)
      end
  """

  @versions %{
    1 => Cyclium.Migrations.V1,
    2 => Cyclium.Migrations.V2,
    3 => Cyclium.Migrations.V3,
    4 => Cyclium.Migrations.V4,
    5 => Cyclium.Migrations.V5,
    6 => Cyclium.Migrations.V6,
    7 => Cyclium.Migrations.V7,
    8 => Cyclium.Migrations.V8
  }

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

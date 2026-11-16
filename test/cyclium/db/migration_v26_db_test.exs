defmodule Cyclium.MigrationV26DbTest do
  use Cyclium.DataCase

  test "V26 runs up and down on SQLite, where there is no ALTER COLUMN" do
    version = 9_026_000_000 + System.unique_integer([:positive])

    assert :ok = Ecto.Migrator.up(Repo, version, Cyclium.Migrations.V26, log: false)
    assert :ok = Ecto.Migrator.down(Repo, version, Cyclium.Migrations.V26, log: false)
  end
end

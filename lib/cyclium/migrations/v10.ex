defmodule Cyclium.Migrations.V10 do
  @moduledoc """
  V10: Findings causality and TTL support.

  Adds `caused_by_key` for finding causality tracking and
  `expires_at` for automatic finding expiration (TTL).
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_findings) do
      add(:caused_by_key, :string, size: 512)
      add(:expires_at, :utc_datetime)
    end

    create(index(:cyclium_findings, [:caused_by_key]))
    create(index(:cyclium_findings, [:expires_at]))
  end

  def down do
    drop_if_exists(index(:cyclium_findings, [:expires_at]))
    drop_if_exists(index(:cyclium_findings, [:caused_by_key]))

    alter table(:cyclium_findings) do
      remove(:caused_by_key)
      remove(:expires_at)
    end
  end
end

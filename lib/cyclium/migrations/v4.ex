defmodule Cyclium.Migrations.V4 do
  @moduledoc """
  V4: Add archived_at to episodes and findings for soft-archive support.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_episodes) do
      add(:archived_at, :utc_datetime)
    end

    alter table(:cyclium_findings) do
      add(:archived_at, :utc_datetime)
    end

    create(index(:cyclium_episodes, [:archived_at]))
    create(index(:cyclium_findings, [:archived_at]))
  end

  def down do
    drop(index(:cyclium_findings, [:archived_at]))
    drop(index(:cyclium_episodes, [:archived_at]))

    alter table(:cyclium_findings) do
      remove(:archived_at)
    end

    alter table(:cyclium_episodes) do
      remove(:archived_at)
    end
  end
end

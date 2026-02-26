defmodule Cyclium.Migrations.V5 do
  @moduledoc """
  V5: Unique index on episodes dedupe_key for multi-node coordination.

  Replaces the non-unique index from V1 with a filtered unique index.
  NULL dedupe_keys and archived episodes are excluded — archived episodes
  can reuse dedupe_keys so re-triggered work isn't blocked.
  """

  use Ecto.Migration

  def up do
    drop(index(:cyclium_episodes, [:dedupe_key]))

    create(
      unique_index(:cyclium_episodes, [:dedupe_key],
        where: "dedupe_key IS NOT NULL AND archived_at IS NULL"
      )
    )
  end

  def down do
    drop(index(:cyclium_episodes, [:dedupe_key]))
    create(index(:cyclium_episodes, [:dedupe_key]))
  end
end

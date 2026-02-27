defmodule Cyclium.Migrations.V7 do
  @moduledoc """
  V7: Dynamic agent definitions table and dry run support.

  - `cyclium_agent_definitions` — stores DB-defined actors that can be
    hydrated into running supervised processes at runtime.
  - Adds `mode` and `dry_run_opts` columns to `cyclium_episodes` for
    simulation/dry-run support.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_agent_definitions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:actor_id, :string, size: 255, null: false)
      add(:domain, :string, size: 255)
      add(:config, :text)
      add(:expectations, :text)
      add(:strategy_ref, :string, size: 255)
      add(:strategy_template, :string, size: 255)
      add(:strategy_config, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:created_by, :string, size: 255)
      add(:inserted_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:cyclium_agent_definitions, [:actor_id]))

    alter table(:cyclium_episodes) do
      add(:mode, :string, size: 32, default: "live")
      add(:dry_run_opts, :text)
    end
  end

  def down do
    alter table(:cyclium_episodes) do
      remove(:mode)
      remove(:dry_run_opts)
    end

    drop(table(:cyclium_agent_definitions))
  end
end

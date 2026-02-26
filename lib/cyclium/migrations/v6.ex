defmodule Cyclium.Migrations.V6 do
  @moduledoc """
  V6: Work claims table for lease-based distributed coordination.

  Enables at-most-once execution of episodes across clustered nodes.
  Each claim row represents a lease on a dedupe_key — only the node
  holding an active lease executes the work.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_work_claims, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:dedupe_key, :string, size: 512, null: false)
      add(:state, :string, size: 32, null: false)
      add(:owner_node, :string, size: 255, null: false)
      add(:lease_until, :utc_datetime, null: false)
      add(:claimed_at, :utc_datetime, null: false)
      add(:last_heartbeat_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
      add(:attempt, :integer, null: false, default: 1)
      add(:work_type, :string, size: 128)
      add(:error_detail, :map)
    end

    create(unique_index(:cyclium_work_claims, [:dedupe_key]))
    create(index(:cyclium_work_claims, [:state, :lease_until]))
  end

  def down do
    drop(table(:cyclium_work_claims))
  end
end

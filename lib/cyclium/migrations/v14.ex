defmodule Cyclium.Migrations.V14 do
  @moduledoc """
  V14: Add cyclium_trigger_requests table for deferred episode execution.

  Supports trigger-only mode where nodes create episodes but defer execution
  to full-mode nodes via a polled request table.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_trigger_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:actor_id, :string, null: false)
      add(:expectation_id, :string, null: false)
      add(:source_node, :string, null: false)
      add(:source_stack, :string)
      add(:status, :string, null: false, default: "pending")
      add(:opts, :map, default: %{})
      add(:claimed_by, :string)
      add(:claimed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:cyclium_trigger_requests, [:status, :inserted_at]))
    create(index(:cyclium_trigger_requests, [:episode_id]))
  end

  def down do
    drop(table(:cyclium_trigger_requests))
  end
end

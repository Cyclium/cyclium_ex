defmodule Cyclium.Migrations.V8 do
  @moduledoc """
  V8: Dynamic workflow definitions table.

  Stores DB-defined workflows that can be hydrated and registered
  with the WorkflowEngine at runtime.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_workflow_definitions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:workflow_id, :string, size: 255, null: false)
      add(:trigger_type, :string, size: 50, null: false)
      add(:trigger_event, :string, size: 255)
      add(:steps, :text, null: false)
      add(:failure_policies, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:created_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:cyclium_workflow_definitions, [:workflow_id]))
  end

  def down do
    drop(table(:cyclium_workflow_definitions))
  end
end

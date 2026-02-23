defmodule Cyclium.Migrations.V3 do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:cyclium_workflow_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_id, :string, null: false
      add :trigger_ref, :map
      add :status, :string, null: false, default: "running"
      add :step_states, :map, default: "{}"
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :created_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime
    end

    create index(:cyclium_workflow_instances, [:status])
    create index(:cyclium_workflow_instances, [:workflow_id])
  end

  def down do
    drop table(:cyclium_workflow_instances)
  end
end

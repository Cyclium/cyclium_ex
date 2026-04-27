defmodule Cyclium.Migrations.V20 do
  @moduledoc """
  V20: Add `subject_value` column to `cyclium_workflow_instances`.

  Backs the cross-node dedup gate in `Cyclium.WorkflowEngine`. The engine
  extracts the value of the workflow's declared `subject_key` from each
  triggering payload and stamps it on the instance. Workflows without a
  `subject_key`, and rows that predate this migration, get the sentinel
  string `"_"` so the column is `NOT NULL` and queryable.

  Pairs with a `Cyclium.WorkClaims` claim keyed on
  `"workflow:<stack>:<workflow_id>:<subject_value>"` to prevent two nodes
  in the same stack from creating duplicate instances for the same
  triggering event.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_workflow_instances) do
      add(:subject_value, :string, null: false, default: "_")
    end

    create(index(:cyclium_workflow_instances, [:workflow_id, :subject_value]))
  end

  def down do
    drop_if_exists(index(:cyclium_workflow_instances, [:workflow_id, :subject_value]))

    alter table(:cyclium_workflow_instances) do
      remove(:subject_value)
    end
  end
end

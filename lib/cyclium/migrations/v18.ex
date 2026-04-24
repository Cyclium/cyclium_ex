defmodule Cyclium.Migrations.V18 do
  @moduledoc """
  V18: Add `source_stack` to `cyclium_episodes` and `cyclium_workflow_instances`.

  Scopes recovery sweeps and workflow reconciliation to the stack that
  originated the work. Mirrors the existing `source_stack` column on
  `cyclium_trigger_requests` (added in V14). Existing rows are left NULL
  and treated as "match any stack" by Recovery for one release so legacy
  episodes aren't orphaned.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_episodes) do
      add(:source_stack, :string)
    end

    alter table(:cyclium_workflow_instances) do
      add(:source_stack, :string)
    end

    create(index(:cyclium_episodes, [:source_stack, :status]))
    create(index(:cyclium_workflow_instances, [:source_stack, :status]))
  end

  def down do
    drop_if_exists(index(:cyclium_workflow_instances, [:source_stack, :status]))
    drop_if_exists(index(:cyclium_episodes, [:source_stack, :status]))

    alter table(:cyclium_workflow_instances) do
      remove(:source_stack)
    end

    alter table(:cyclium_episodes) do
      remove(:source_stack)
    end
  end
end

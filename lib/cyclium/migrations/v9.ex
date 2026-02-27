defmodule Cyclium.Migrations.V9 do
  @moduledoc """
  V9: Dry run support for workflow instances.

  Adds `mode` and `dry_run_opts` columns to `cyclium_workflow_instances`
  so workflow dry runs propagate mode to all step episodes.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_workflow_instances) do
      add(:mode, :string, size: 32, default: "live")
      add(:dry_run_opts, :text)
    end
  end

  def down do
    alter table(:cyclium_workflow_instances) do
      remove(:mode)
      remove(:dry_run_opts)
    end
  end
end

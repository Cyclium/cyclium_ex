defmodule Cyclium.Migrations.V12 do
  @moduledoc """
  V12: Add expectation_id to findings for scoped escalation rules.

  Findings previously linked to expectations only indirectly through
  raised_by_episode_id. This column enables the escalation sweep to
  scope rules to the correct (actor_id, expectation_id) pair without
  joining episodes.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_findings) do
      add(:expectation_id, :string)
    end
  end

  def down do
    alter table(:cyclium_findings) do
      remove(:expectation_id)
    end
  end
end

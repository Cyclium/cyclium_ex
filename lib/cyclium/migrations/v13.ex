defmodule Cyclium.Migrations.V13 do
  @moduledoc """
  V13: Replace findings unique index with a partial index excluding superseded.

  The original unique index on (finding_key, status) prevents multiple
  superseded rows for the same finding_key, which causes constraint
  violations when the expiration sweep archives cleared findings that
  have prior superseded history. Superseded is a terminal archive state
  and should not be constrained.
  """

  use Ecto.Migration

  def up do
    drop(unique_index(:cyclium_findings, [:finding_key, :status]))

    create(
      unique_index(:cyclium_findings, [:finding_key, :status],
        where: "status != 'superseded'",
        name: :cyclium_findings_finding_key_status_index
      )
    )
  end

  def down do
    drop(
      index(:cyclium_findings, [:finding_key, :status],
        name: :cyclium_findings_finding_key_status_index
      )
    )

    create(unique_index(:cyclium_findings, [:finding_key, :status]))
  end
end

defmodule Cyclium.Migrations.V11 do
  @moduledoc """
  V11: Episode timestamp precision and workflow ordering.

  - Promotes `started_at` and `finished_at` from second-precision
    (:utc_datetime) to microsecond-precision (:utc_datetime_usec) so that
    sequential episodes naturally sort correctly without tiebreakers.
  - Promotes `queued_at` to :utc_datetime_usec for the same reason.
  - Adds `workflow_step_no` — the topological depth of the episode's step in
    the workflow DAG (root steps = 0, each dependent layer +1). Used as a
    stable tiebreaker for truly parallel steps that fire at the same instant.
  """

  use Ecto.Migration

  def up do
    # SQLite stores datetimes as text and does not support ALTER COLUMN.
    # The precision upgrade is meaningless there, so skip the modify block
    # and just add the new column.
    if sqlite?() do
      alter table(:cyclium_episodes) do
        add(:workflow_step_no, :integer)
      end
    else
      alter table(:cyclium_episodes) do
        modify(:started_at, :utc_datetime_usec)
        modify(:finished_at, :utc_datetime_usec)
        modify(:queued_at, :utc_datetime_usec)
        add(:workflow_step_no, :integer)
      end
    end
  end

  def down do
    if sqlite?() do
      alter table(:cyclium_episodes) do
        remove(:workflow_step_no)
      end
    else
      alter table(:cyclium_episodes) do
        modify(:started_at, :utc_datetime)
        modify(:finished_at, :utc_datetime)
        modify(:queued_at, :utc_datetime)
        remove(:workflow_step_no)
      end
    end
  end

  defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3
end

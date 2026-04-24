defmodule Cyclium.Migrations.V17 do
  @moduledoc """
  V17: Upgrade timestamp columns to microsecond precision.

  Enables sub-second ordering of episode steps and accurate episode timing,
  critical for correlating Cyclium events with external system logs.
  """

  use Ecto.Migration

  def up do
    # SQLite stores datetimes as text and does not support ALTER COLUMN.
    # The precision upgrade is meaningless there — the migration is a no-op.
    unless sqlite?() do
      alter table(:cyclium_episode_steps) do
        modify(:created_at, :utc_datetime_usec, from: :utc_datetime)
      end

      # SQL Server refuses ALTER COLUMN while any index references the column
      # (error 4922). Two indexes depend on archived_at:
      #   - V4: index(:cyclium_episodes, [:archived_at])
      #   - V5: unique_index(:cyclium_episodes, [:dedupe_key],
      #                      where: "... AND archived_at IS NULL")
      # Drop both before the modify, recreate after. Safe on Postgres too.
      drop_if_exists(index(:cyclium_episodes, [:archived_at]))
      drop_if_exists(index(:cyclium_episodes, [:dedupe_key]))

      alter table(:cyclium_episodes) do
        modify(:started_at, :utc_datetime_usec, from: :utc_datetime)
        modify(:finished_at, :utc_datetime_usec, from: :utc_datetime)
        modify(:queued_at, :utc_datetime_usec, from: :utc_datetime)
        modify(:archived_at, :utc_datetime_usec, from: :utc_datetime)
      end

      create(index(:cyclium_episodes, [:archived_at]))

      create(
        unique_index(:cyclium_episodes, [:dedupe_key],
          where: "dedupe_key IS NOT NULL AND archived_at IS NULL"
        )
      )
    end
  end

  def down do
    unless sqlite?() do
      alter table(:cyclium_episode_steps) do
        modify(:created_at, :utc_datetime, from: :utc_datetime_usec)
      end

      drop_if_exists(index(:cyclium_episodes, [:archived_at]))
      drop_if_exists(index(:cyclium_episodes, [:dedupe_key]))

      alter table(:cyclium_episodes) do
        modify(:started_at, :utc_datetime, from: :utc_datetime_usec)
        modify(:finished_at, :utc_datetime, from: :utc_datetime_usec)
        modify(:queued_at, :utc_datetime, from: :utc_datetime_usec)
        modify(:archived_at, :utc_datetime, from: :utc_datetime_usec)
      end

      create(index(:cyclium_episodes, [:archived_at]))

      create(
        unique_index(:cyclium_episodes, [:dedupe_key],
          where: "dedupe_key IS NOT NULL AND archived_at IS NULL"
        )
      )
    end
  end

  defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3
end

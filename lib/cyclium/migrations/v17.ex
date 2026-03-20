defmodule Cyclium.Migrations.V17 do
  @moduledoc """
  V17: Upgrade timestamp columns to microsecond precision.

  Enables sub-second ordering of episode steps and accurate episode timing,
  critical for correlating Cyclium events with external system logs.
  """

  use Ecto.Migration

  def up do
    # Episode steps: created_at
    alter table(:cyclium_episode_steps) do
      modify(:created_at, :utc_datetime_usec, from: :utc_datetime)
    end

    # Episodes: started_at, finished_at, queued_at, archived_at
    alter table(:cyclium_episodes) do
      modify(:started_at, :utc_datetime_usec, from: :utc_datetime)
      modify(:finished_at, :utc_datetime_usec, from: :utc_datetime)
      modify(:queued_at, :utc_datetime_usec, from: :utc_datetime)
      modify(:archived_at, :utc_datetime_usec, from: :utc_datetime)
    end
  end

  def down do
    alter table(:cyclium_episode_steps) do
      modify(:created_at, :utc_datetime, from: :utc_datetime_usec)
    end

    alter table(:cyclium_episodes) do
      modify(:started_at, :utc_datetime, from: :utc_datetime_usec)
      modify(:finished_at, :utc_datetime, from: :utc_datetime_usec)
      modify(:queued_at, :utc_datetime, from: :utc_datetime_usec)
      modify(:archived_at, :utc_datetime, from: :utc_datetime_usec)
    end
  end
end

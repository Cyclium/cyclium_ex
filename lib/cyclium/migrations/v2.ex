defmodule Cyclium.Migrations.V2 do
  @moduledoc """
  V2: Episode logs table for LogProjector.

  SQL Server 2017 compatible — uses :text (nvarchar(max)) for content.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_episode_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      add :format, :string, null: false, default: "markdown"
      add :content, :text
      add :last_step_no_rendered, :integer, null: false, default: 0
      add :created_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime
    end

    create unique_index(:cyclium_episode_logs, [:episode_id])
  end

  def down do
    drop table(:cyclium_episode_logs)
  end
end

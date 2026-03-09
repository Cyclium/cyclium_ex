defmodule Cyclium.Migrations.V15 do
  @moduledoc """
  V15: Interactive actors — conversations table, conversation_id on episodes
  and workflow_instances, parent_episode_id on episodes, plan_preview step kind.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_conversations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:status, :string, null: false, default: "open")
      add(:actor_id, :string)
      add(:goal, :string)
      add(:origin, :string)
      add(:audience_target, :string)
      add(:result, :string)
      add(:resolved_outcome, :string)
      add(:principal, :string)
      add(:principal_id, :string, size: 255)
      add(:collected_fields, :string)
      add(:turns_used, :integer, default: 0)
      add(:tokens_used, :integer, default: 0)
      add(:inserted_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(index(:cyclium_conversations, [:status]))
    create(index(:cyclium_conversations, [:principal_id]))
    create(index(:cyclium_conversations, [:actor_id, :status]))

    alter table(:cyclium_episodes) do
      add(
        :conversation_id,
        references(:cyclium_conversations, type: :binary_id, on_delete: :nilify_all), null: true)

      add(:parent_episode_id, :string, null: true)
    end

    create(index(:cyclium_episodes, [:conversation_id]))
    create(index(:cyclium_episodes, [:parent_episode_id]))

    alter table(:cyclium_workflow_instances) do
      add(
        :conversation_id,
        references(:cyclium_conversations, type: :binary_id, on_delete: :nilify_all), null: true)
    end

    create(index(:cyclium_workflow_instances, [:conversation_id]))
  end

  def down do
    drop_if_exists(index(:cyclium_workflow_instances, [:conversation_id]))

    alter table(:cyclium_workflow_instances) do
      remove(:conversation_id)
    end

    drop_if_exists(index(:cyclium_episodes, [:parent_episode_id]))
    drop_if_exists(index(:cyclium_episodes, [:conversation_id]))

    alter table(:cyclium_episodes) do
      remove(:parent_episode_id)
      remove(:conversation_id)
    end

    drop(table(:cyclium_conversations))
  end
end

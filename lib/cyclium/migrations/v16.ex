defmodule Cyclium.Migrations.V16 do
  @moduledoc """
  V16: Add principal_type to conversations, add principal columns to agent_definitions.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_conversations) do
      add(:principal_type, :string, size: 255)
    end

    create(index(:cyclium_conversations, [:principal_type]))

    alter table(:cyclium_agent_definitions) do
      add(:principal_id, :string, size: 255)
      add(:principal, :text)
      add(:principal_type, :string, size: 255)
    end
  end

  def down do
    alter table(:cyclium_agent_definitions) do
      remove(:principal_type)
      remove(:principal)
      remove(:principal_id)
    end

    drop_if_exists(index(:cyclium_conversations, [:principal_type]))

    alter table(:cyclium_conversations) do
      remove(:principal_type)
    end
  end
end

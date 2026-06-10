defmodule Cyclium.Migrations.V23 do
  @moduledoc """
  V23: Record which interactive expectation a conversation uses.

  Adds a nullable `expectation_id` column to `cyclium_conversations`. When an
  actor declares more than one interactive expectation, a conversation can pin
  the one it belongs to, so dispatch routes each turn to the right expectation
  without the caller passing it every time. `NULL` means "auto-resolve" (the
  single interactive expectation), preserving existing behaviour for legacy rows.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_conversations) do
      add(:expectation_id, :string)
    end
  end

  def down do
    alter table(:cyclium_conversations) do
      remove(:expectation_id)
    end
  end
end

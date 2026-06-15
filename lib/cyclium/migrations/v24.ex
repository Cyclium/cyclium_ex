defmodule Cyclium.Migrations.V24 do
  @moduledoc """
  V24: Downloadable exports (`cyclium_exports`).

  A durable, pull-based artifact an actor produces for a user to download (e.g. a
  CSV). Unlike `cyclium_outputs` (channel-delivered, deduped, redacted), an
  export is a blob fetched on demand via a signed link, scoped to the principal
  that requested it and expiring after a TTL. Backs `Cyclium.Exports` /
  `Cyclium.Tools.CsvExport`.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_exports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :nilify_all))
      add(:conversation_id, :binary_id)

      add(:principal_type, :string, null: false)
      add(:principal_id, :string, null: false)

      add(:type, :string, null: false, default: "csv")
      add(:filename, :string, null: false)
      add(:content_type, :string, null: false, default: "text/csv")
      add(:content, :text)
      add(:byte_size, :integer, null: false, default: 0)

      add(:created_at, :utc_datetime, null: false)
      add(:expires_at, :utc_datetime)
    end

    create(index(:cyclium_exports, [:principal_type, :principal_id]))
    create(index(:cyclium_exports, [:expires_at]))
  end

  def down do
    drop(table(:cyclium_exports))
  end
end

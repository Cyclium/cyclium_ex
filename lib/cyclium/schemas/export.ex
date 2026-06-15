defmodule Cyclium.Schemas.Export do
  @moduledoc """
  Schema for the `cyclium_exports` table — a durable, downloadable artifact an
  actor produced for a principal (e.g. a CSV). Fetched on demand via a signed
  link and expiring after a TTL. See `Cyclium.Exports`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "cyclium_exports" do
    field(:episode_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:principal_type, :string)
    field(:principal_id, :string)
    field(:type, :string, default: "csv")
    field(:filename, :string)
    field(:content_type, :string, default: "text/csv")
    field(:content, :string)
    field(:byte_size, :integer, default: 0)
    field(:created_at, :utc_datetime)
    field(:expires_at, :utc_datetime)
  end

  def changeset(export, attrs) do
    export
    |> cast(attrs, [
      :episode_id,
      :conversation_id,
      :principal_type,
      :principal_id,
      :type,
      :filename,
      :content_type,
      :content,
      :byte_size,
      :created_at,
      :expires_at
    ])
    |> validate_required([:principal_type, :principal_id, :type, :filename, :created_at])
  end
end

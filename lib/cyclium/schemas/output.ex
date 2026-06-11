defmodule Cyclium.Schemas.Output do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:proposed, :delivered, :failed, :canceled]

  @type t :: %__MODULE__{}

  schema "cyclium_outputs" do
    field(:episode_id, :binary_id)
    field(:type, :string)
    field(:dedupe_key, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :proposed)
    field(:payload_redacted, :map)
    field(:delivered_ref, :map)
    field(:error_class, :string)
    field(:error_detail, :map)
    field(:created_at, :utc_datetime)
    field(:delivered_at, :utc_datetime)
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [
      :episode_id,
      :type,
      :dedupe_key,
      :status,
      :payload_redacted,
      :delivered_ref,
      :error_class,
      :error_detail,
      :created_at,
      :delivered_at
    ])
    |> validate_required([:episode_id, :type, :dedupe_key, :status, :created_at])
    |> unique_constraint(:dedupe_key)
  end
end

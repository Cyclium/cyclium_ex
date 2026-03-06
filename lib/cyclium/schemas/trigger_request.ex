defmodule Cyclium.Schemas.TriggerRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :claimed, :completed, :expired]

  schema "cyclium_trigger_requests" do
    field(:episode_id, :binary_id)
    field(:actor_id, :string)
    field(:expectation_id, :string)
    field(:source_node, :string)
    field(:source_stack, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :pending)
    field(:opts, :map, default: %{})
    field(:claimed_by, :string)
    field(:claimed_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :episode_id,
      :actor_id,
      :expectation_id,
      :source_node,
      :source_stack,
      :status,
      :opts,
      :claimed_by,
      :claimed_at
    ])
    |> validate_required([:episode_id, :actor_id, :expectation_id, :source_node, :status])
  end
end

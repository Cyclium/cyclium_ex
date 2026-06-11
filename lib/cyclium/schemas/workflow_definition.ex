defmodule Cyclium.Schemas.WorkflowDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "cyclium_workflow_definitions" do
    field(:workflow_id, :string)
    field(:trigger_type, :string)
    field(:trigger_event, :string)
    field(:steps, :string)
    field(:failure_policies, :string)
    field(:enabled, :boolean, default: true)
    field(:created_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
  end

  def changeset(defn, attrs) do
    defn
    |> cast(attrs, [
      :workflow_id,
      :trigger_type,
      :trigger_event,
      :steps,
      :failure_policies,
      :enabled,
      :created_at,
      :updated_at
    ])
    |> validate_required([:workflow_id, :trigger_type, :steps, :created_at, :updated_at])
    |> validate_inclusion(:trigger_type, ["event", "manual"])
    |> unique_constraint(:workflow_id)
  end
end

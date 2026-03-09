defmodule Cyclium.Schemas.WorkflowInstance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses [:running, :blocked, :done, :failed, :canceled]

  schema "cyclium_workflow_instances" do
    field(:workflow_id, :string)
    field(:trigger_ref, :map)
    field(:status, Ecto.Enum, values: @statuses, default: :running)
    field(:step_states, :map, default: %{})
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:conversation_id, :binary_id)
    field(:mode, :string, default: "live")
    field(:dry_run_opts, :map)
    field(:created_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :workflow_id,
      :trigger_ref,
      :status,
      :step_states,
      :conversation_id,
      :mode,
      :dry_run_opts,
      :started_at,
      :finished_at,
      :created_at,
      :updated_at
    ])
    |> validate_required([:workflow_id, :status, :started_at, :created_at])
  end
end

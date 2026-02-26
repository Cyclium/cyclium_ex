defmodule Cyclium.Schemas.Episode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:running, :blocked, :done, :failed, :partially_failed, :canceled]
  @trigger_types [:schedule, :event, :drift, :manual, :workflow]

  schema "cyclium_episodes" do
    field(:actor_id, :string)
    field(:expectation_id, :string)
    field(:spec_rev, :string)
    field(:trigger_type, Ecto.Enum, values: @trigger_types)
    field(:trigger_ref, :map)
    field(:dedupe_key, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :running)
    field(:phase, :string)
    field(:budget, :map)
    field(:turns_used, :integer, default: 0)
    field(:tokens_used, :integer, default: 0)
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: 3)
    field(:classification, :map)
    field(:confidence, :float)
    field(:summary, :string)
    field(:log_strategy, :string)
    field(:error_class, :string)
    field(:error_detail, :map)
    field(:workflow_instance_id, :binary_id)
    field(:workflow_step_id, :string)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:queued_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    has_many(:steps, Cyclium.Schemas.EpisodeStep)
    has_many(:checkpoints, Cyclium.Schemas.EpisodeCheckpoint)
    has_many(:outputs, Cyclium.Schemas.Output)
  end

  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :actor_id,
      :expectation_id,
      :spec_rev,
      :trigger_type,
      :trigger_ref,
      :dedupe_key,
      :status,
      :phase,
      :budget,
      :turns_used,
      :tokens_used,
      :attempts,
      :max_attempts,
      :classification,
      :confidence,
      :summary,
      :log_strategy,
      :error_class,
      :error_detail,
      :workflow_instance_id,
      :workflow_step_id,
      :started_at,
      :finished_at,
      :queued_at,
      :archived_at
    ])
    |> validate_required([:actor_id, :expectation_id, :trigger_type, :status, :started_at])
    |> unique_constraint(:dedupe_key, name: :cyclium_episodes_dedupe_key_index)
  end
end

defmodule Cyclium.Schemas.EpisodeStep do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @step_kinds [
    :tool_call, :synthesis, :observation, :checkpoint,
    :output_proposed, :output_delivered, :output_failed,
    :approval_requested, :approval_resolved,
    :wait_started, :wait_resolved,
    :finding_raised, :finding_cleared,
    :episode_completed, :episode_failed
  ]

  schema "cyclium_episode_steps" do
    field :episode_id, :binary_id
    field :step_no, :integer
    field :kind, Ecto.Enum, values: @step_kinds
    field :tool_name, :string
    field :args_hash, :string
    field :args_redacted, :map
    field :result_ref, :map
    field :error_class, :string
    field :error_detail, :map
    field :side_effect_key, :string
    field :cost_tokens, :integer
    field :cost_ms, :integer
    field :created_at, :utc_datetime
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :episode_id, :step_no, :kind, :tool_name, :args_hash, :args_redacted,
      :result_ref, :error_class, :error_detail, :side_effect_key,
      :cost_tokens, :cost_ms, :created_at
    ])
    |> validate_required([:episode_id, :step_no, :kind, :created_at])
  end
end

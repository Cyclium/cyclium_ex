defmodule Cyclium.Schemas.Finding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:active, :cleared, :superseded]
  @severities [:low, :medium, :high, :critical]

  @type t :: %__MODULE__{}

  schema "cyclium_findings" do
    field(:actor_id, :string)
    field(:expectation_id, :string)
    field(:finding_key, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :active)
    field(:class, :string)
    field(:severity, Ecto.Enum, values: @severities)
    field(:confidence, :float)
    field(:subject, :map)
    field(:evidence_refs, :map)
    field(:summary, :string)
    field(:raised_by_episode_id, :binary_id)
    field(:cleared_by_episode_id, :binary_id)
    field(:raised_at, :utc_datetime)
    field(:cleared_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
    # Denormalized from subject map for SQL Server indexable queries
    field(:subject_kind, :string)
    field(:subject_id, :string)
    field(:archived_at, :utc_datetime)
    # V10: Causality and TTL
    field(:caused_by_key, :string)
    field(:expires_at, :utc_datetime)
    # V22: per-env cordoning (see Cyclium.Env). NULL == the unset/default env.
    field(:env, :string)
  end

  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [
      :actor_id,
      :expectation_id,
      :finding_key,
      :status,
      :class,
      :severity,
      :confidence,
      :subject,
      :evidence_refs,
      :summary,
      :raised_by_episode_id,
      :cleared_by_episode_id,
      :raised_at,
      :cleared_at,
      :updated_at,
      :subject_kind,
      :subject_id,
      :archived_at,
      :caused_by_key,
      :expires_at,
      :env
    ])
    |> validate_required([
      :actor_id,
      :finding_key,
      :status,
      :class,
      :raised_by_episode_id,
      :raised_at
    ])
    |> maybe_denormalize_subject()
    |> unique_constraint([:finding_key, :status, :env],
      name: :cyclium_findings_finding_key_status_env_index
    )
  end

  defp maybe_denormalize_subject(changeset) do
    case get_change(changeset, :subject) do
      %{"kind" => kind, "id" => id} ->
        changeset |> put_change(:subject_kind, kind) |> put_change(:subject_id, id)

      %{kind: kind, id: id} ->
        changeset
        |> put_change(:subject_kind, to_string(kind))
        |> put_change(:subject_id, to_string(id))

      _ ->
        changeset
    end
  end
end

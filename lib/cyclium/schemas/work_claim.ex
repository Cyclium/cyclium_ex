defmodule Cyclium.Schemas.WorkClaim do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  # An expired lease is NOT a distinct state — it's a `:claimed` row whose
  # `lease_until` has elapsed (re-acquired via the takeover path). There is no
  # `:expired` state because nothing ever writes one.
  @states [:claimed, :done, :failed]

  @type t :: %__MODULE__{
          id: binary() | nil,
          dedupe_key: String.t() | nil,
          state: :claimed | :done | :failed | nil,
          owner_node: String.t() | nil,
          lease_until: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          attempt: integer(),
          fence: integer(),
          work_type: String.t() | nil,
          error_detail: map() | nil
        }

  schema "cyclium_work_claims" do
    field(:dedupe_key, :string)
    field(:state, Ecto.Enum, values: @states)
    field(:owner_node, :string)
    field(:lease_until, :utc_datetime)
    field(:claimed_at, :utc_datetime)
    field(:last_heartbeat_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:attempt, :integer, default: 1)
    field(:fence, :integer, default: 0)
    field(:work_type, :string)
    field(:error_detail, :map)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :dedupe_key,
      :state,
      :owner_node,
      :lease_until,
      :claimed_at,
      :last_heartbeat_at,
      :finished_at,
      :attempt,
      :fence,
      :work_type,
      :error_detail
    ])
    |> validate_required([:dedupe_key, :state, :owner_node, :lease_until, :claimed_at])
    |> unique_constraint(:dedupe_key)
  end
end

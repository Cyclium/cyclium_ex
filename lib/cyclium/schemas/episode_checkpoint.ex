defmodule Cyclium.Schemas.EpisodeCheckpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cyclium_episode_checkpoints" do
    field :episode_id, :binary_id
    field :checkpoint_no, :integer
    field :phase, :string
    field :schema_version, :integer
    field :state, :map
    field :created_at, :utc_datetime
  end

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:episode_id, :checkpoint_no, :phase, :schema_version, :state, :created_at])
    |> validate_required([:episode_id, :checkpoint_no, :phase, :schema_version, :state, :created_at])
  end
end

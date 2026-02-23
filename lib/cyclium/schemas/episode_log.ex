defmodule Cyclium.Schemas.EpisodeLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cyclium_episode_logs" do
    field :episode_id, :binary_id
    field :format, :string, default: "markdown"
    field :content, :string
    field :last_step_no_rendered, :integer, default: 0
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:episode_id, :format, :content, :last_step_no_rendered, :created_at, :updated_at])
    |> validate_required([:episode_id, :format, :created_at])
    |> unique_constraint(:episode_id)
  end
end

defmodule Cyclium.Schemas.AgentDefinition do
  @moduledoc """
  Schema for DB-stored actor definitions. These are hydrated into
  running `Cyclium.DynamicActor` processes at runtime by the Loader.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "cyclium_agent_definitions" do
    field(:actor_id, :string)
    field(:domain, :string)
    field(:config, :string)
    field(:expectations, :string)
    field(:strategy_ref, :string)
    field(:strategy_template, :string)
    field(:strategy_config, :string)
    field(:enabled, :boolean, default: true)
    field(:created_by, :string)
    field(:principal_id, :string)
    field(:principal, :string)
    field(:principal_type, :string)
    field(:inserted_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
  end

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :actor_id,
      :domain,
      :config,
      :expectations,
      :strategy_ref,
      :strategy_template,
      :strategy_config,
      :enabled,
      :created_by,
      :principal_id,
      :principal,
      :principal_type,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([:actor_id])
    |> unique_constraint(:actor_id)
  end
end

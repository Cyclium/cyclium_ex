defmodule Cyclium.Schemas.Conversation do
  @moduledoc """
  Schema for the `cyclium_conversations` table.
  A conversation is the container for a multi-turn interactive session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :status,
             :actor_id,
             :expectation_id,
             :goal,
             :origin,
             :audience_target,
             :result,
             :resolved_outcome,
             :principal,
             :principal_id,
             :principal_type,
             :collected_fields,
             :turns_used,
             :tokens_used,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ["awaiting_participant", "open", "resolved", "abandoned", "timed_out"]

  schema "cyclium_conversations" do
    field(:name, :string)
    field(:status, :string, default: "open")
    field(:actor_id, :string)
    field(:expectation_id, :string)
    field(:goal, :string)
    field(:origin, :string)
    field(:audience_target, :string)
    field(:result, :string)
    field(:resolved_outcome, :string)
    field(:principal, :string)
    field(:principal_id, :string)
    field(:principal_type, :string)
    field(:collected_fields, :string)
    field(:turns_used, :integer, default: 0)
    field(:tokens_used, :integer, default: 0)

    has_many(:episodes, Cyclium.Schemas.Episode, foreign_key: :conversation_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :name,
      :status,
      :actor_id,
      :expectation_id,
      :goal,
      :origin,
      :audience_target,
      :result,
      :resolved_outcome,
      :principal,
      :principal_id,
      :principal_type,
      :collected_fields,
      :turns_used,
      :tokens_used
    ])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses

  # JSON field helpers. A malformed column value decodes to the field's empty
  # value with a warning, rather than raising into whichever LiveView, hook or
  # loader touched the row.

  def decode_goal(%__MODULE__{goal: nil}), do: nil

  def decode_goal(%__MODULE__{goal: json} = c) when is_binary(json),
    do: decode(c, :goal, json, nil)

  def decode_origin(%__MODULE__{origin: nil}), do: nil

  def decode_origin(%__MODULE__{origin: json} = c) when is_binary(json),
    do: decode(c, :origin, json, nil)

  def decode_audience_target(%__MODULE__{audience_target: nil}), do: nil

  def decode_audience_target(%__MODULE__{audience_target: json} = c) when is_binary(json),
    do: decode(c, :audience_target, json, nil)

  def decode_principal(%__MODULE__{principal: nil}), do: nil

  def decode_principal(%__MODULE__{principal: json} = c) when is_binary(json),
    do: decode(c, :principal, json, nil)

  def decode_result(%__MODULE__{result: nil}), do: nil

  def decode_result(%__MODULE__{result: json} = c) when is_binary(json),
    do: decode(c, :result, json, nil)

  def decode_collected_fields(%__MODULE__{collected_fields: nil}), do: %{}

  def decode_collected_fields(%__MODULE__{collected_fields: json} = c) when is_binary(json),
    do: decode(c, :collected_fields, json, %{})

  defp decode(conversation, field, json, default) do
    case Jason.decode(json) do
      {:ok, value} ->
        value

      {:error, _} ->
        require Logger

        Logger.warning(
          "[Cyclium.Schemas.Conversation] #{field} on conversation #{conversation.id} is not valid JSON; using #{inspect(default)}"
        )

        default
    end
  end
end

defmodule Cyclium.Conversations do
  @moduledoc """
  Context module for managing interactive conversations.
  Provides start, claim, resolve, abandon, and query operations.
  """

  import Ecto.Query
  require Logger

  alias Cyclium.Schemas.Conversation

  # --- Create ---

  @doc """
  Start a new conversation.

  ## Required fields
    - `:actor_id` — which interactive actor handles this conversation
    - `:name` — display name

  ## Optional fields
    - `:principal` — map with "type", "id", "label"
    - `:goal` — GoalSpec map (JSON-encoded on write)
    - `:origin` — Origin map
    - `:audience_target` — AudienceTarget map
  """
  @spec start(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def start(attrs) do
    principal = attrs[:principal]
    origin = attrs[:origin]
    audience_target = attrs[:audience_target]

    initial_status =
      cond do
        # User-initiated: they're already here
        is_map(principal) and principal["id"] ->
          "open"

        # Workflow/system-initiated with known principal
        is_map(audience_target) and audience_target["mode"] == "principal" ->
          "awaiting_participant"

        # Pool or any
        is_map(audience_target) ->
          "awaiting_participant"

        # Default
        true ->
          "open"
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset_attrs = %{
      name: attrs[:name] || "Conversation #{DateTime.to_iso8601(now)}",
      status: attrs[:status] || initial_status,
      actor_id: to_string_or_nil(attrs[:actor_id]),
      expectation_id: to_string_or_nil(attrs[:expectation_id]),
      goal: encode_json(attrs[:goal]),
      origin: encode_json(origin),
      audience_target: encode_json(audience_target),
      principal: encode_json(principal),
      principal_id: get_in_map(principal, "id"),
      principal_type: get_in_map(principal, "type"),
      collected_fields: encode_json(%{}),
      turns_used: 0,
      tokens_used: 0
    }

    %Conversation{}
    |> Conversation.changeset(changeset_attrs)
    |> Cyclium.repo().insert()
    |> tap_ok(fn conv ->
      if initial_status == "awaiting_participant" do
        Cyclium.Bus.broadcast("conversation.awaiting_participant", %{
          conversation_id: conv.id,
          actor_id: conv.actor_id,
          audience_target: audience_target
        })
      end
    end)
  end

  # --- Claim ---

  @doc """
  Claim a conversation (for :pool and :any audience modes).
  Sets the principal and transitions status to :open.
  """
  @spec claim(binary(), map()) ::
          {:ok, Conversation.t()} | {:error, :already_claimed | :not_found}
  def claim(conversation_id, principal) when is_map(principal) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      %{status: "awaiting_participant"} = conv ->
        conv
        |> Conversation.changeset(%{
          status: "open",
          principal: encode_json(principal),
          principal_id: principal["id"],
          principal_type: principal["type"]
        })
        |> Cyclium.repo().update()

      %{principal_id: existing_id} when not is_nil(existing_id) ->
        {:error, :already_claimed}

      conv ->
        conv
        |> Conversation.changeset(%{
          principal: encode_json(principal),
          principal_id: principal["id"],
          principal_type: principal["type"]
        })
        |> Cyclium.repo().update()
    end
  end

  # --- Resolve ---

  @doc """
  Resolve a conversation with an outcome and result.
  """
  @spec resolve(binary(), binary(), map()) :: {:ok, Conversation.t()} | {:error, term()}
  def resolve(conversation_id, outcome, result \\ %{}) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["resolved", "abandoned", "timed_out"] ->
        {:error, :already_terminal}

      conv ->
        conv
        |> Conversation.changeset(%{
          status: "resolved",
          resolved_outcome: outcome,
          result: encode_json(result)
        })
        |> Cyclium.repo().update()
        |> tap_ok(fn updated ->
          Cyclium.Bus.broadcast("conversation.resolved", %{
            conversation_id: updated.id,
            outcome: outcome,
            result: result,
            actor_id: updated.actor_id
          })
        end)
    end
  end

  # --- Abandon ---

  @spec abandon(binary(), binary()) :: {:ok, Conversation.t()} | {:error, term()}
  def abandon(conversation_id, reason \\ "user_abandoned") do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["resolved", "abandoned", "timed_out"] ->
        {:error, :already_terminal}

      conv ->
        conv
        |> Conversation.changeset(%{
          status: "abandoned",
          result: encode_json(%{reason: reason})
        })
        |> Cyclium.repo().update()
        |> tap_ok(fn updated ->
          Cyclium.Bus.broadcast("conversation.abandoned", %{
            conversation_id: updated.id,
            reason: reason,
            actor_id: updated.actor_id
          })
        end)
    end
  end

  # --- Timeout ---

  @spec timeout(binary()) :: {:ok, Conversation.t()} | {:error, term()}
  def timeout(conversation_id) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["resolved", "abandoned", "timed_out"] ->
        {:error, :already_terminal}

      conv ->
        conv
        |> Conversation.changeset(%{status: "timed_out"})
        |> Cyclium.repo().update()
        |> tap_ok(fn updated ->
          Cyclium.Bus.broadcast("conversation.timed_out", %{
            conversation_id: updated.id,
            actor_id: updated.actor_id
          })
        end)
    end
  end

  # --- Update collected fields ---

  @spec update_collected_fields(binary(), map()) :: {:ok, Conversation.t()} | {:error, term()}
  def update_collected_fields(conversation_id, new_fields) when is_map(new_fields) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        existing = Conversation.decode_collected_fields(conv)
        merged = Map.merge(existing, new_fields)

        conv
        |> Conversation.changeset(%{collected_fields: encode_json(merged)})
        |> Cyclium.repo().update()
    end
  end

  # --- Increment turn ---

  @spec increment_turn(binary(), non_neg_integer()) :: {:ok, Conversation.t()} | {:error, term()}
  def increment_turn(conversation_id, tokens \\ 0) do
    case get(conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        conv
        |> Conversation.changeset(%{
          turns_used: (conv.turns_used || 0) + 1,
          tokens_used: (conv.tokens_used || 0) + tokens
        })
        |> Cyclium.repo().update()
    end
  end

  # --- Query ---

  @spec get(binary()) :: Conversation.t() | nil
  def get(id), do: Cyclium.repo().get(Conversation, id)

  @spec get!(binary()) :: Conversation.t()
  def get!(id), do: Cyclium.repo().get!(Conversation, id)

  @spec list_for_principal(binary(), keyword()) :: [Conversation.t()]
  def list_for_principal(principal_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    from(c in Conversation,
      where: c.principal_id == ^principal_id,
      order_by: [desc: c.updated_at]
    )
    |> maybe_filter_status(status)
    |> Cyclium.repo().all()
  end

  @spec list_for_actor(binary() | atom(), keyword()) :: [Conversation.t()]
  def list_for_actor(actor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in Conversation,
      where: c.actor_id == ^to_string(actor_id),
      order_by: [desc: c.updated_at],
      limit: ^limit
    )
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> Cyclium.repo().all()
  end

  @spec list_awaiting(keyword()) :: [Conversation.t()]
  def list_awaiting(opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)

    from(c in Conversation,
      where: c.status == "awaiting_participant",
      order_by: [asc: c.inserted_at]
    )
    |> maybe_filter_actor(actor_id)
    |> Cyclium.repo().all()
  end

  @spec check_constraints(Conversation.t()) ::
          :ok | {:warn, :last_turn} | {:error, :budget_exceeded}
  def check_constraints(%Conversation{} = conv) do
    goal = Conversation.decode_goal(conv)
    constraints = (goal && goal["constraints"]) || %{}

    max_turns = constraints["max_turns"]
    max_tokens = constraints["max_total_tokens"]
    timeout_minutes = constraints["timeout_minutes"]

    cond do
      max_turns && conv.turns_used >= max_turns ->
        {:error, :budget_exceeded}

      max_tokens && conv.tokens_used >= max_tokens ->
        {:error, :budget_exceeded}

      timeout_minutes && timed_out?(conv, timeout_minutes) ->
        {:error, :budget_exceeded}

      max_turns && conv.turns_used == max_turns - 1 ->
        {:warn, :last_turn}

      true ->
        :ok
    end
  end

  # --- Private ---

  defp timed_out?(conv, timeout_minutes) do
    deadline = DateTime.add(conv.inserted_at, timeout_minutes * 60, :second)
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [c], c.status == ^status)

  defp maybe_filter_actor(query, nil), do: query

  defp maybe_filter_actor(query, actor_id),
    do: where(query, [c], c.actor_id == ^to_string(actor_id))

  defp encode_json(nil), do: nil
  defp encode_json(data) when is_map(data), do: Jason.encode!(data)
  defp encode_json(data) when is_binary(data), do: data

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  defp get_in_map(nil, _key), do: nil
  defp get_in_map(map, key) when is_map(map), do: Map.get(map, key)

  defp tap_ok({:ok, val} = result, fun) do
    fun.(val)
    result
  end

  defp tap_ok(other, _fun), do: other
end

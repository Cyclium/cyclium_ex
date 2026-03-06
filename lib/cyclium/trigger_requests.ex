defmodule Cyclium.TriggerRequests do
  @moduledoc """
  Context module for deferred trigger requests.

  Trigger requests are created by `Runner.Deferred` on trigger-only nodes
  and picked up by `TriggerRequests.Poller` on full-mode nodes.
  """

  import Ecto.Query

  alias Cyclium.Schemas.TriggerRequest

  def create(attrs) do
    %TriggerRequest{}
    |> TriggerRequest.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Claims up to `limit` pending trigger requests for the given node.

  Uses an optimistic update: only rows still in `:pending` status are claimed.
  Optionally scopes to requests from a specific source stack.
  """
  def claim_pending(claimer_node, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    source_stack = Keyword.get(opts, :source_stack)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base_query =
      from(r in TriggerRequest,
        where: r.status == :pending,
        order_by: [asc: r.inserted_at],
        limit: ^limit,
        select: r.id
      )

    query =
      if source_stack do
        from(r in base_query, where: r.source_stack == ^to_string(source_stack))
      else
        base_query
      end

    ids = repo().all(query)

    if ids == [] do
      {:ok, []}
    else
      {_count, claimed} =
        from(r in TriggerRequest,
          where: r.id in ^ids and r.status == :pending,
          select: r
        )
        |> repo().update_all(
          set: [claimed_by: claimer_node, claimed_at: now, status: :claimed, updated_at: now]
        )

      {:ok, claimed}
    end
  end

  def mark_completed(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(r in TriggerRequest, where: r.id == ^id)
    |> repo().update_all(set: [status: :completed, updated_at: now])

    :ok
  end

  def mark_expired(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(r in TriggerRequest, where: r.id == ^id)
    |> repo().update_all(set: [status: :expired, updated_at: now])

    :ok
  end

  @doc """
  Expires trigger requests that have been pending longer than `max_age_seconds`.
  """
  def expire_stale(max_age_seconds \\ 3600) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_age_seconds, :second)
      |> DateTime.truncate(:second)

    {count, _} =
      from(r in TriggerRequest,
        where: r.status == :pending and r.inserted_at < ^cutoff
      )
      |> repo().update_all(set: [status: :expired])

    {:ok, count}
  end

  defp repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

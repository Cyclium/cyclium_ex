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
  Fetches up to `limit` pending trigger requests, oldest first.

  ## Options

    * `:limit` — max rows (default: 10)
    * `:source_stack` — when set, only requests from this stack (nil = any stack)
    * `:source_env` — when present, only requests from this env, matched by
      **strict equality** (so an env-tagged poller never claims the default
      env's requests). Pass `nil` to scope to the unset/default env; omit the
      key entirely to skip env filtering.

  Does not modify the rows — claiming is handled via `WorkClaims`.
  """
  def fetch_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    source_stack = Keyword.get(opts, :source_stack)

    query =
      from(r in TriggerRequest,
        where: r.status == :pending,
        order_by: [asc: r.inserted_at],
        limit: ^limit
      )
      |> maybe_filter_source_stack(source_stack)
      |> filter_source_env(Keyword.get(opts, :source_env, :__unset__))

    {:ok, repo().all(query)}
  end

  defp maybe_filter_source_stack(query, nil), do: query

  defp maybe_filter_source_stack(query, source_stack),
    do: from(r in query, where: r.source_stack == ^to_string(source_stack))

  defp filter_source_env(query, :__unset__), do: query
  defp filter_source_env(query, nil), do: from(r in query, where: is_nil(r.source_env))

  defp filter_source_env(query, env),
    do: from(r in query, where: r.source_env == ^to_string(env))

  def mark_claimed(id, claimer_node) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(r in TriggerRequest, where: r.id == ^id)
    |> repo().update_all(
      set: [claimed_by: claimer_node, claimed_at: now, status: :claimed, updated_at: now]
    )

    :ok
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

  ## Options

    * `:source_env` — when present, only expires requests from this env, matched
      by **strict equality** (so a poller never GCs another env's pending
      requests). Pass `nil` to scope to the unset/default env; omit to expire
      across all envs. The poller passes its own env, mirroring `fetch_pending/1`.
  """
  def expire_stale(max_age_seconds \\ 3600, opts \\ []) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_age_seconds, :second)
      |> DateTime.truncate(:second)

    {count, _} =
      from(r in TriggerRequest,
        where: r.status == :pending and r.inserted_at < ^cutoff
      )
      |> filter_source_env(Keyword.get(opts, :source_env, :__unset__))
      |> repo().update_all(set: [status: :expired])

    {:ok, count}
  end

  defp repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

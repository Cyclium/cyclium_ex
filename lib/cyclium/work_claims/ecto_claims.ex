defmodule Cyclium.WorkClaims.EctoClaims do
  @moduledoc """
  Default Ecto-based work claims implementation.

  Uses transactions with read-then-write to coordinate claims.
  Works with any Ecto adapter. For SQL Server-optimized claiming
  with `UPDLOCK` hints, implement the `Cyclium.WorkClaims` behaviour
  in your consuming app.
  """

  @behaviour Cyclium.WorkClaims

  import Ecto.Query

  alias Cyclium.Schemas.WorkClaim

  @default_lease_seconds 120

  @impl true
  def acquire(dedupe_key, owner_node, opts \\ []) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    now = DateTime.utc_now()
    lease_until = DateTime.add(now, lease_seconds, :second)

    repo().transaction(fn ->
      case repo().one(from(c in WorkClaim, where: c.dedupe_key == ^dedupe_key)) do
        nil ->
          %WorkClaim{}
          |> WorkClaim.changeset(%{
            dedupe_key: dedupe_key,
            state: :claimed,
            owner_node: owner_node,
            lease_until: lease_until,
            claimed_at: now,
            attempt: 1,
            work_type: Keyword.get(opts, :work_type)
          })
          |> repo().insert!()

        %{state: :claimed, lease_until: lu} = existing ->
          if DateTime.compare(lu, now) == :gt do
            repo().rollback(:busy)
          else
            # Lease expired — steal it
            existing
            |> WorkClaim.changeset(%{
              state: :claimed,
              owner_node: owner_node,
              lease_until: lease_until,
              claimed_at: now,
              last_heartbeat_at: nil,
              finished_at: nil,
              attempt: existing.attempt + 1
            })
            |> repo().update!()
          end

        %{state: :done} = completed ->
          completed
          |> WorkClaim.changeset(%{
            state: :claimed,
            owner_node: owner_node,
            lease_until: lease_until,
            claimed_at: now,
            last_heartbeat_at: nil,
            finished_at: nil,
            attempt: 1
          })
          |> repo().update!()

        %{} = expired ->
          expired
          |> WorkClaim.changeset(%{
            state: :claimed,
            owner_node: owner_node,
            lease_until: lease_until,
            claimed_at: now,
            last_heartbeat_at: nil,
            finished_at: nil,
            attempt: expired.attempt + 1
          })
          |> repo().update!()
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, :busy} -> {:error, :busy}
    end
  end

  @impl true
  def renew(dedupe_key, owner_node, lease_seconds) do
    now = DateTime.utc_now()
    lease_until = DateTime.add(now, lease_seconds, :second)

    from(c in WorkClaim,
      where:
        c.dedupe_key == ^dedupe_key and
          c.owner_node == ^owner_node and
          c.state == :claimed
    )
    |> repo().update_all(set: [lease_until: lease_until, last_heartbeat_at: now])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_owner}
    end
  end

  @impl true
  def complete(dedupe_key, owner_node) do
    now = DateTime.utc_now()

    from(c in WorkClaim,
      where:
        c.dedupe_key == ^dedupe_key and
          c.owner_node == ^owner_node and
          c.state == :claimed
    )
    |> repo().update_all(set: [state: "done", finished_at: now])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_owner}
    end
  end

  @impl true
  def fail(dedupe_key, owner_node, error_detail \\ %{}) do
    now = DateTime.utc_now()

    from(c in WorkClaim,
      where:
        c.dedupe_key == ^dedupe_key and
          c.owner_node == ^owner_node and
          c.state == :claimed
    )
    |> repo().update_all(set: [state: "failed", finished_at: now, error_detail: error_detail])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_owner}
    end
  end

  @impl true
  def reclaim_expired(limit \\ 100) do
    now = DateTime.utc_now()

    expired =
      from(c in WorkClaim,
        where: c.state == :claimed and c.lease_until < ^now,
        limit: ^limit
      )
      |> repo().all()

    {:ok, expired}
  end

  defp repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

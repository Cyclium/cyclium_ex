defmodule Cyclium.WorkClaims.EctoClaims do
  @moduledoc """
  Default Ecto-based work claims implementation. Works with any Ecto adapter.

  Acquisition is race-free without row locks: every takeover is a single
  conditional `UPDATE ... WHERE <the state we read still holds>` and we treat a
  zero-row result as "someone else won" (`:busy`). A brand-new claim is an
  `INSERT` whose unique `dedupe_key` index turns a concurrent first-acquire into
  `:busy` rather than a duplicate. This preserves at-most-once across nodes on
  READ COMMITTED (the Postgres/SQL Server default) — two nodes can never both
  believe they hold the same lease.

  A SQL Server adapter using `UPDLOCK`/`READPAST` hints is an optional
  throughput optimization, not a correctness requirement.

  The `state` column is an `Ecto.Enum` — all reads and writes use atoms
  (`:claimed`, `:done`, `:failed`, `:expired`).
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

    case repo().one(from(c in WorkClaim, where: c.dedupe_key == ^dedupe_key)) do
      nil ->
        insert_claim(dedupe_key, owner_node, now, lease_until, opts)

      %WorkClaim{} = existing ->
        take_over(existing, dedupe_key, owner_node, now, lease_until)
    end
  end

  # No row yet — insert. A concurrent simultaneous insert loses to the unique
  # dedupe_key index and is reported as :busy (the winner holds a fresh lease).
  defp insert_claim(dedupe_key, owner_node, now, lease_until, opts) do
    %WorkClaim{}
    |> WorkClaim.changeset(%{
      dedupe_key: dedupe_key,
      state: :claimed,
      owner_node: owner_node,
      lease_until: lease_until,
      claimed_at: now,
      attempt: 1,
      fence: 1,
      work_type: Keyword.get(opts, :work_type)
    })
    |> repo().insert()
    |> case do
      {:ok, claim} ->
        {:ok, claim}

      {:error, %Ecto.Changeset{} = changeset} ->
        if dedupe_conflict?(changeset) do
          {:error, :busy}
        else
          raise "[Cyclium.WorkClaims.EctoClaims] unexpected insert failure: " <>
                  inspect(changeset.errors)
        end
    end
  end

  # A claimed row: busy if the lease is still active, otherwise steal it.
  defp take_over(%{state: :claimed, lease_until: lease_until}, key, owner, now, new_lease) do
    if not is_nil(lease_until) and DateTime.compare(lease_until, now) == :gt do
      {:error, :busy}
    else
      # Steal an expired claimed lease. Guard: still claimed AND still expired, so
      # concurrent stealers win at most once (the loser matches 0 rows → :busy).
      from(c in WorkClaim,
        where: c.dedupe_key == ^key and c.state == :claimed and c.lease_until < ^now
      )
      |> repo().update_all(set: takeover_set(owner, now, new_lease), inc: [attempt: 1, fence: 1])
      |> finish_take_over(key)
    end
  end

  # Re-claim a completed slot, resetting the attempt counter (fence still
  # increments — it's a monotonic ownership generation, not a retry count).
  defp take_over(%{state: :done}, key, owner, now, new_lease) do
    from(c in WorkClaim, where: c.dedupe_key == ^key and c.state == :done)
    |> repo().update_all(
      set: [{:attempt, 1} | takeover_set(owner, now, new_lease)],
      inc: [fence: 1]
    )
    |> finish_take_over(key)
  end

  # Re-claim a failed/expired slot, incrementing the attempt counter.
  defp take_over(%{state: state}, key, owner, now, new_lease) do
    from(c in WorkClaim, where: c.dedupe_key == ^key and c.state == ^state)
    |> repo().update_all(set: takeover_set(owner, now, new_lease), inc: [attempt: 1, fence: 1])
    |> finish_take_over(key)
  end

  defp takeover_set(owner_node, now, lease_until) do
    [
      state: :claimed,
      owner_node: owner_node,
      lease_until: lease_until,
      claimed_at: now,
      last_heartbeat_at: nil,
      finished_at: nil
    ]
  end

  # {1, _} → we won the guarded update; reload and return the fresh claim.
  # {0, _} → the row no longer matched (someone else took it) → busy.
  defp finish_take_over({1, _}, key),
    do: {:ok, repo().one(from(c in WorkClaim, where: c.dedupe_key == ^key))}

  defp finish_take_over({0, _}, _key), do: {:error, :busy}

  defp dedupe_conflict?(%Ecto.Changeset{errors: errors}),
    do: Keyword.has_key?(errors, :dedupe_key)

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
    |> repo().update_all(set: [state: :done, finished_at: now])
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
    |> repo().update_all(set: [state: :failed, finished_at: now, error_detail: error_detail])
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

  @impl true
  def owns?(dedupe_key, owner_node, fence) do
    repo().exists?(
      from(c in WorkClaim,
        where:
          c.dedupe_key == ^dedupe_key and
            c.owner_node == ^owner_node and
            c.state == :claimed and
            c.fence == ^fence
      )
    )
  end

  defp repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

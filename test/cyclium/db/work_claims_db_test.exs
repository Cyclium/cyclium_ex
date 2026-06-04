defmodule Cyclium.WorkClaimsDbTest do
  @moduledoc """
  Integration tests for Cyclium.WorkClaims.EctoClaims against a real SQLite DB.

  The key behavior under test is distributed deduplication: only one node
  should be able to hold an active lease on a given dedupe_key at a time.

  Tests also cover lease stealing (expired claims), lifecycle transitions
  (complete/fail), renewal, and the gate_* passthrough when unconfigured.
  """
  use Cyclium.DataCase

  alias Cyclium.WorkClaims
  alias Cyclium.WorkClaims.EctoClaims
  alias Cyclium.Schemas.WorkClaim

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp unique_key, do: "test:claim:#{System.unique_integer([:positive])}"

  defp future(seconds \\ 120), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp past(seconds \\ 10), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp insert_claim(attrs) do
    defaults = %{
      dedupe_key: unique_key(),
      state: :claimed,
      owner_node: "node@test",
      lease_until: future(),
      claimed_at: DateTime.utc_now(),
      attempt: 1
    }

    Repo.insert!(WorkClaim.changeset(%WorkClaim{}, Map.merge(defaults, attrs)))
  end

  # ─── acquire ──────────────────────────────────────────────────────────────

  describe "EctoClaims.acquire/3" do
    test "first acquire inserts a new claim and returns it" do
      key = unique_key()
      assert {:ok, claim} = EctoClaims.acquire(key, "node@a")

      assert claim.dedupe_key == key
      assert claim.state == :claimed
      assert claim.owner_node == "node@a"
      assert claim.attempt == 1
    end

    test "second acquire on same key with active lease returns :busy" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      # Different node tries to claim the same key while lease is still valid
      assert {:error, :busy} = EctoClaims.acquire(key, "node@b")
    end

    test "same node acquiring same key with active lease also returns :busy" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")
      assert {:error, :busy} = EctoClaims.acquire(key, "node@a")
    end

    test "acquire steals an expired claimed lease and increments attempt" do
      key = unique_key()
      insert_claim(%{dedupe_key: key, owner_node: "node@old", lease_until: past()})

      assert {:ok, stolen} = EctoClaims.acquire(key, "node@new")
      assert stolen.owner_node == "node@new"
      assert stolen.state == :claimed
      assert stolen.attempt == 2
      assert Repo.aggregate(WorkClaim, :count) == 1
    end

    test "acquire re-claims a done claim and resets attempt to 1" do
      key = unique_key()
      insert_claim(%{dedupe_key: key, state: :done, lease_until: past(), attempt: 5})

      assert {:ok, reclaimed} = EctoClaims.acquire(key, "node@new", lease_seconds: 60)
      assert reclaimed.state == :claimed
      assert reclaimed.attempt == 1
    end

    test "acquire re-claims a failed claim and increments attempt" do
      key = unique_key()
      insert_claim(%{dedupe_key: key, state: :failed, lease_until: past(), attempt: 3})

      assert {:ok, reclaimed} = EctoClaims.acquire(key, "node@retry")
      assert reclaimed.state == :claimed
      assert reclaimed.attempt == 4
    end

    test "stores work_type when provided" do
      key = unique_key()
      {:ok, claim} = EctoClaims.acquire(key, "node@a", work_type: "episode")
      assert claim.work_type == "episode"
    end
  end

  # ─── concurrent acquire (race safety) ──────────────────────────────────────

  describe "EctoClaims.acquire/3 under concurrency" do
    setup do
      # Allow spawned tasks to share the test's sandboxed connection.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    test "only one of many concurrent first-acquires wins; the rest get :busy (no crash)" do
      key = unique_key()

      results =
        1..8
        |> Task.async_stream(fn i -> EctoClaims.acquire(key, "node-#{i}") end,
          max_concurrency: 8,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :busy})) == 7
      # Exactly one row exists — no duplicate, no raised ConstraintError.
      assert Repo.aggregate(WorkClaim, :count) == 1
    end

    test "only one of many concurrent steals of an expired lease wins" do
      key = unique_key()
      insert_claim(%{dedupe_key: key, owner_node: "node@old", lease_until: past()})

      results =
        1..8
        |> Task.async_stream(fn i -> EctoClaims.acquire(key, "node-#{i}") end,
          max_concurrency: 8,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :busy})) == 7

      # The single surviving row has exactly one owner among the contenders.
      claim = Repo.get_by!(WorkClaim, dedupe_key: key)
      assert claim.state == :claimed
      assert claim.owner_node =~ "node-"
    end
  end

  # ─── renew ────────────────────────────────────────────────────────────────

  describe "EctoClaims.renew/3" do
    test "renews the lease for the owning node" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert :ok = EctoClaims.renew(key, "node@a", 300)

      claim = Repo.get_by!(WorkClaim, dedupe_key: key)
      assert DateTime.compare(claim.lease_until, future(299)) == :gt
    end

    test "returns :not_owner when a different node tries to renew" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert {:error, :not_owner} = EctoClaims.renew(key, "node@b", 60)
    end

    test "returns :not_owner when claim does not exist" do
      assert {:error, :not_owner} = EctoClaims.renew("nonexistent:key", "node@a", 60)
    end
  end

  # ─── complete ─────────────────────────────────────────────────────────────

  describe "EctoClaims.complete/2" do
    test "marks the claim as done for the owning node" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert :ok = EctoClaims.complete(key, "node@a")

      claim = Repo.get_by!(WorkClaim, dedupe_key: key)
      assert claim.state == :done
      assert claim.finished_at != nil
    end

    test "returns :not_owner when a different node tries to complete" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert {:error, :not_owner} = EctoClaims.complete(key, "node@b")
      assert Repo.get_by!(WorkClaim, dedupe_key: key).state == :claimed
    end
  end

  # ─── fail ─────────────────────────────────────────────────────────────────

  describe "EctoClaims.fail/3" do
    test "marks the claim as failed with error detail" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert :ok = EctoClaims.fail(key, "node@a", %{reason: "timeout"})

      claim = Repo.get_by!(WorkClaim, dedupe_key: key)
      assert claim.state == :failed
      assert claim.error_detail["reason"] == "timeout"
      assert claim.finished_at != nil
    end

    test "returns :not_owner when a different node tries to fail" do
      key = unique_key()
      {:ok, _} = EctoClaims.acquire(key, "node@a")

      assert {:error, :not_owner} = EctoClaims.fail(key, "node@b", %{})
    end
  end

  # ─── reclaim_expired ──────────────────────────────────────────────────────

  describe "EctoClaims.reclaim_expired/1" do
    test "returns claimed records whose lease has expired, not active ones" do
      expired = insert_claim(%{dedupe_key: unique_key(), lease_until: past()})
      active = insert_claim(%{dedupe_key: unique_key(), lease_until: future()})

      {:ok, results} = EctoClaims.reclaim_expired(100)
      ids = Enum.map(results, & &1.id)

      assert expired.id in ids
      refute active.id in ids
    end

    test "respects the limit" do
      for _ <- 1..5, do: insert_claim(%{dedupe_key: unique_key(), lease_until: past()})

      {:ok, results} = EctoClaims.reclaim_expired(2)
      assert length(results) == 2
    end

    test "returns empty list when no expired claims exist" do
      insert_claim(%{dedupe_key: unique_key(), lease_until: future()})

      {:ok, results} = EctoClaims.reclaim_expired(100)
      assert results == []
    end
  end

  # ─── gate_* passthrough ───────────────────────────────────────────────────

  describe "WorkClaims gate functions — unconfigured passthrough" do
    setup do
      # Ensure work_claims is NOT configured for these tests
      Application.delete_env(:cyclium, :work_claims)
      on_exit(fn -> Application.delete_env(:cyclium, :work_claims) end)
    end

    test "gate_acquire returns :passthrough when dedupe_key is nil" do
      assert {:ok, :passthrough} = WorkClaims.gate_acquire(nil, "node@a")
    end

    test "gate_acquire returns :passthrough when no impl is configured" do
      assert {:ok, :passthrough} = WorkClaims.gate_acquire("some:key", "node@a")
    end

    test "gate_renew returns :ok when no impl is configured" do
      assert :ok = WorkClaims.gate_renew("some:key", "node@a", 60)
    end

    test "gate_complete returns :ok when no impl is configured" do
      assert :ok = WorkClaims.gate_complete("some:key", "node@a")
    end

    test "gate_fail returns :ok when no impl is configured" do
      assert :ok = WorkClaims.gate_fail("some:key", "node@a", %{})
    end
  end

  # ─── gate_acquire with real impl ─────────────────────────────────────────

  describe "WorkClaims gate_acquire — with EctoClaims configured" do
    setup do
      Application.put_env(:cyclium, :work_claims, EctoClaims)
      on_exit(fn -> Application.delete_env(:cyclium, :work_claims) end)
    end

    test "delegates to EctoClaims and returns the claim" do
      key = unique_key()
      assert {:ok, claim} = WorkClaims.gate_acquire(key, "node@a")
      assert %WorkClaim{} = claim
      assert claim.dedupe_key == key
    end

    test "returns :busy when claim is already held" do
      key = unique_key()
      {:ok, _} = WorkClaims.gate_acquire(key, "node@a")
      assert {:error, :busy} = WorkClaims.gate_acquire(key, "node@b")
    end
  end
end

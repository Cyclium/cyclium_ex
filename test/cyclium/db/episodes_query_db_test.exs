defmodule Cyclium.EpisodesQueryDbTest do
  @moduledoc """
  Integration tests for episode query functions that FakeRepo.all/one
  stubs out entirely (always returning [] or nil).

  Covers: list_by_actors query options, list_stale_running subquery,
  and cancel_related multi-episode operation.
  """
  use Cyclium.DataCase

  alias Cyclium.Episodes
  alias Cyclium.Schemas.{Episode, EpisodeStep}

  # ─── list_by_actors query options ──────────────────────────────────────────

  describe "list_by_actors/2 — status filter" do
    test "returns only episodes matching the given statuses" do
      running = insert_episode(%{actor_id: "qa", status: :running})
      _done = insert_episode(%{actor_id: "qa", status: :done})

      results = Episodes.list_by_actors(["qa"], statuses: [:running])

      assert length(results) == 1
      assert hd(results).id == running.id
    end

    test "returns all statuses when statuses option is omitted" do
      insert_episode(%{actor_id: "qb", status: :running})
      insert_episode(%{actor_id: "qb", status: :done})

      results = Episodes.list_by_actors(["qb"])
      assert length(results) == 2
    end

    test "returns empty list when no episodes match the status" do
      insert_episode(%{actor_id: "qc", status: :running})

      results = Episodes.list_by_actors(["qc"], statuses: [:done])
      assert results == []
    end
  end

  describe "list_by_actors/2 — exclude_archived" do
    test "includes archived episodes by default" do
      now = DateTime.utc_now()
      insert_episode(%{actor_id: "qa2", archived_at: now})
      insert_episode(%{actor_id: "qa2"})

      results = Episodes.list_by_actors(["qa2"])
      assert length(results) == 2
    end

    test "excludes archived episodes when exclude_archived: true" do
      now = DateTime.utc_now()
      _archived = insert_episode(%{actor_id: "qa3", archived_at: now})
      live = insert_episode(%{actor_id: "qa3"})

      results = Episodes.list_by_actors(["qa3"], exclude_archived: true)
      assert length(results) == 1
      assert hd(results).id == live.id
    end
  end

  describe "list_by_actors/2 — limit and offset" do
    test "limit caps the number of results" do
      for _ <- 1..5, do: insert_episode(%{actor_id: "ql"})

      results = Episodes.list_by_actors(["ql"], limit: 3)
      assert length(results) == 3
    end

    test "offset skips rows" do
      # Insert 3 in ascending started_at order
      t0 = DateTime.add(DateTime.utc_now(), -30, :second)
      t1 = DateTime.add(DateTime.utc_now(), -20, :second)
      t2 = DateTime.add(DateTime.utc_now(), -10, :second)

      first = insert_episode(%{actor_id: "qo", started_at: t0})
      _second = insert_episode(%{actor_id: "qo", started_at: t1})
      third = insert_episode(%{actor_id: "qo", started_at: t2})

      # desc order, offset 1 skips the most recent → returns middle + oldest
      page = Episodes.list_by_actors(["qo"], order: :desc, limit: 2, offset: 1)
      ids = Enum.map(page, & &1.id)

      refute third.id in ids
      assert first.id in ids
    end
  end

  # ─── list_stale_running ─────────────────────────────────────────────────────

  describe "list_stale_running/1" do
    test "returns running episode with no steps older than the threshold" do
      old_start = DateTime.add(DateTime.utc_now(), -10, :second)
      stale = insert_episode(%{started_at: old_start, status: :running})

      # stale_after_ms = 5 seconds; episode started 10s ago with no steps
      results = Episodes.list_stale_running(5_000)
      ids = Enum.map(results, & &1.id)

      assert stale.id in ids
    end

    test "excludes running episode whose most recent step is fresh" do
      old_start = DateTime.add(DateTime.utc_now(), -10, :second)
      fresh_ep = insert_episode(%{started_at: old_start, status: :running})

      insert_step(%{
        episode_id: fresh_ep.id,
        step_no: 1,
        created_at: DateTime.utc_now()
      })

      results = Episodes.list_stale_running(5_000)
      ids = Enum.map(results, & &1.id)

      refute fresh_ep.id in ids
    end

    test "returns running episode whose only step is old" do
      old_time = DateTime.add(DateTime.utc_now(), -10, :second)
      stale_ep = insert_episode(%{started_at: old_time, status: :running})

      insert_step(%{episode_id: stale_ep.id, step_no: 1, created_at: old_time})

      results = Episodes.list_stale_running(5_000)
      ids = Enum.map(results, & &1.id)

      assert stale_ep.id in ids
    end

    test "excludes non-running episodes regardless of age" do
      old_start = DateTime.add(DateTime.utc_now(), -10, :second)
      insert_episode(%{started_at: old_start, status: :done})

      results = Episodes.list_stale_running(5_000)

      # The done episode must not appear (query filters status == :running)
      Enum.each(results, fn ep -> assert ep.status == :running end)
    end

    test "excludes archived running episodes" do
      old_start = DateTime.add(DateTime.utc_now(), -10, :second)

      insert_episode(%{
        started_at: old_start,
        status: :running,
        archived_at: old_start
      })

      results = Episodes.list_stale_running(5_000)
      Enum.each(results, fn ep -> assert is_nil(ep.archived_at) end)
    end
  end

  # ─── cancel_related ─────────────────────────────────────────────────────────

  describe "cancel_related/3" do
    test "cancels running and blocked episodes for the given actor/expectation" do
      running =
        insert_episode(%{actor_id: "cr_actor", expectation_id: "cr_exp", status: :running})

      blocked =
        insert_episode(%{actor_id: "cr_actor", expectation_id: "cr_exp", status: :blocked})

      _done = insert_episode(%{actor_id: "cr_actor", expectation_id: "cr_exp", status: :done})

      assert {:ok, 2} = Episodes.cancel_related("cr_actor", "cr_exp")

      assert Repo.get!(Episode, running.id).status == :canceled
      assert Repo.get!(Episode, blocked.id).status == :canceled
    end

    test "does not touch episodes for a different actor or expectation" do
      other =
        insert_episode(%{actor_id: "other_actor", expectation_id: "cr_exp", status: :running})

      insert_episode(%{actor_id: "cr_actor2", expectation_id: "cr_exp2", status: :running})

      Episodes.cancel_related("cr_actor2", "cr_exp2")

      assert Repo.get!(Episode, other.id).status == :running
    end

    test "returns {:ok, 0} when nothing to cancel" do
      assert {:ok, 0} = Episodes.cancel_related("nobody", "nothing")
    end

    test "journals an episode_failed step for each canceled episode" do
      ep = insert_episode(%{actor_id: "crj", expectation_id: "crj_exp", status: :running})

      Episodes.cancel_related("crj", "crj_exp", "cascade")

      steps =
        Repo.all(
          from(s in EpisodeStep,
            where: s.episode_id == ^ep.id and s.kind == :episode_failed
          )
        )

      assert length(steps) == 1
      assert hd(steps).error_class == "canceled"
    end
  end
end

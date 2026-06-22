defmodule Cyclium.EpisodesDbTest do
  @moduledoc """
  Integration tests that require a real database (SQLite sandbox).
  Covers features that are hard to verify with FakeRepo stubs:
  - claim_for_recovery increments attempts
  - list_by_actors ordering by workflow_step_no and queued_at
  - spec_rev is persisted on episodes
  - work claims have work_type set
  """
  use Cyclium.DataCase

  alias Cyclium.Episodes
  alias Cyclium.Schemas.Episode

  describe "claim_for_recovery/1" do
    test "increments attempts on the episode" do
      episode = insert_episode(%{status: :running, attempts: 0, phase: nil})

      assert {:ok, claimed} = Episodes.claim_for_recovery(episode.id)
      assert claimed.attempts == 1
      assert claimed.phase == "recovering"
    end

    test "returns :already_claimed when episode is not running" do
      episode = insert_episode(%{status: :done})

      assert {:error, :already_claimed} = Episodes.claim_for_recovery(episode.id)
    end

    test "increments attempts on successive recovery calls" do
      episode = insert_episode(%{status: :running, attempts: 2, phase: nil})

      # Reset to running so we can claim again
      Repo.update_all(
        from(e in Episode, where: e.id == ^episode.id),
        set: [status: "running", phase: nil]
      )

      assert {:ok, claimed} = Episodes.claim_for_recovery(episode.id)
      assert claimed.attempts == 3
    end
  end

  describe "merge_metadata/2" do
    test "stamps the metadata bag and merges without clobbering existing keys" do
      episode = insert_episode(%{status: :running})
      assert episode.metadata in [nil, %{}]

      assert {:ok, _} = Episodes.merge_metadata(episode.id, %{"model" => "gpt-5.4"})
      assert Episodes.get!(episode.id).metadata == %{"model" => "gpt-5.4"}

      assert {:ok, _} = Episodes.merge_metadata(episode.id, %{"max_tokens" => 8192})
      reloaded = Episodes.get!(episode.id).metadata
      assert reloaded["model"] == "gpt-5.4"
      assert reloaded["max_tokens"] == 8192
    end
  end

  describe "list_by_actors/2 ordering" do
    test "orders by workflow_step_no ascending within same started_at" do
      now = DateTime.utc_now()

      # Insert two episodes with the same started_at but different workflow_step_no
      ep_depth1 =
        insert_episode(%{
          actor_id: "order_actor",
          started_at: now,
          workflow_step_no: 1,
          queued_at: now
        })

      ep_depth0 =
        insert_episode(%{
          actor_id: "order_actor",
          started_at: now,
          workflow_step_no: 0,
          queued_at: DateTime.add(now, 1, :second)
        })

      results = Episodes.list_by_actors(["order_actor"], order: :asc)
      ids = Enum.map(results, & &1.id)

      assert Enum.find_index(ids, &(&1 == ep_depth0.id)) <
               Enum.find_index(ids, &(&1 == ep_depth1.id))
    end

    test "falls back to queued_at when started_at and workflow_step_no tie" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -5, :second)

      ep_later_queued =
        insert_episode(%{
          actor_id: "tiebreak_actor",
          started_at: now,
          workflow_step_no: 0,
          queued_at: now
        })

      ep_earlier_queued =
        insert_episode(%{
          actor_id: "tiebreak_actor",
          started_at: now,
          workflow_step_no: 0,
          queued_at: earlier
        })

      results = Episodes.list_by_actors(["tiebreak_actor"], order: :asc)
      ids = Enum.map(results, & &1.id)

      assert Enum.find_index(ids, &(&1 == ep_earlier_queued.id)) <
               Enum.find_index(ids, &(&1 == ep_later_queued.id))
    end
  end

  describe "spec_rev field" do
    test "is persisted when provided on insert" do
      episode = insert_episode(%{spec_rev: "v1.2.3"})

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.spec_rev == "v1.2.3"
    end

    test "is nil by default" do
      episode = insert_episode()

      fetched = Repo.get!(Episode, episode.id)
      assert is_nil(fetched.spec_rev)
    end
  end
end

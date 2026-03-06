defmodule Cyclium.TriggerRequestsTest do
  use Cyclium.DataCase, async: false

  alias Cyclium.TriggerRequests

  setup do
    episode = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
    %{episode: episode}
  end

  describe "create/1" do
    test "inserts a pending trigger request", %{episode: episode} do
      assert {:ok, request} =
               TriggerRequests.create(%{
                 episode_id: episode.id,
                 actor_id: "test_actor",
                 expectation_id: "test_exp",
                 source_node: "node-1"
               })

      assert request.status == :pending
      assert request.source_node == "node-1"
      assert request.claimed_by == nil
    end

    test "stores optional fields", %{episode: episode} do
      assert {:ok, request} =
               TriggerRequests.create(%{
                 episode_id: episode.id,
                 actor_id: "test_actor",
                 expectation_id: "test_exp",
                 source_node: "node-1",
                 source_stack: "unity",
                 opts: %{"resume" => true}
               })

      assert request.source_stack == "unity"
      assert request.opts == %{"resume" => true}
    end
  end

  describe "claim_pending/2" do
    test "claims pending requests", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode)

      assert {:ok, [claimed]} = TriggerRequests.claim_pending("claimer-node")
      assert claimed.status == :claimed
      assert claimed.claimed_by == "claimer-node"
    end

    test "returns empty list when no pending requests" do
      assert {:ok, []} = TriggerRequests.claim_pending("claimer-node")
    end

    test "scopes by source_stack when provided", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode, source_stack: "unity")

      assert {:ok, []} = TriggerRequests.claim_pending("node", source_stack: "hatch")
      assert {:ok, [_]} = TriggerRequests.claim_pending("node", source_stack: "unity")
    end

    test "respects limit", %{episode: episode} do
      ep2 = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
      {:ok, _} = create_trigger_request(episode)
      {:ok, _} = create_trigger_request(ep2)

      assert {:ok, claimed} = TriggerRequests.claim_pending("node", limit: 1)
      assert length(claimed) == 1
    end

    test "does not reclaim already claimed requests", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode)

      assert {:ok, [_]} = TriggerRequests.claim_pending("node-a")
      assert {:ok, []} = TriggerRequests.claim_pending("node-b")
    end
  end

  describe "mark_completed/1" do
    test "marks a request as completed", %{episode: episode} do
      {:ok, request} = create_trigger_request(episode)
      {:ok, [claimed]} = TriggerRequests.claim_pending("node")

      assert :ok = TriggerRequests.mark_completed(claimed.id)

      updated = Repo.get!(Cyclium.Schemas.TriggerRequest, request.id)
      assert updated.status == :completed
    end
  end

  describe "expire_stale/1" do
    test "expires old pending requests", %{episode: episode} do
      {:ok, request} = create_trigger_request(episode)

      # Manually backdate the inserted_at
      Repo.update_all(
        from(r in Cyclium.Schemas.TriggerRequest, where: r.id == ^request.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert {:ok, 1} = TriggerRequests.expire_stale(60)

      updated = Repo.get!(Cyclium.Schemas.TriggerRequest, request.id)
      assert updated.status == :expired
    end

    test "does not expire recent requests", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode)
      assert {:ok, 0} = TriggerRequests.expire_stale(3600)
    end
  end

  defp create_trigger_request(episode, extra \\ []) do
    attrs =
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        expectation_id: episode.expectation_id,
        source_node: "source-node"
      }
      |> Map.merge(Map.new(extra))

    TriggerRequests.create(attrs)
  end
end

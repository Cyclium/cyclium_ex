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
                 source_stack: "stack_a",
                 opts: %{"resume" => true}
               })

      assert request.source_stack == "stack_a"
      assert request.opts == %{"resume" => true}
    end
  end

  describe "fetch_pending/1" do
    test "fetches pending requests", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode)

      assert {:ok, [request]} = TriggerRequests.fetch_pending()
      assert request.status == :pending
    end

    test "returns empty list when no pending requests" do
      assert {:ok, []} = TriggerRequests.fetch_pending()
    end

    test "scopes by source_stack when provided", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode, source_stack: "stack_a")

      assert {:ok, []} = TriggerRequests.fetch_pending(source_stack: "stack_b")
      assert {:ok, [_]} = TriggerRequests.fetch_pending(source_stack: "stack_a")
    end

    test "scopes by source_env with strict equality", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode, source_env: "rc")
      ep2 = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
      {:ok, _} = create_trigger_request(ep2, source_env: nil)

      # An env-tagged poller sees only its own env...
      assert {:ok, [%{source_env: "rc"}]} = TriggerRequests.fetch_pending(source_env: "rc")
      # ...and the default-env poller (nil) sees only NULL rows — NOT "rc".
      assert {:ok, [%{source_env: nil}]} = TriggerRequests.fetch_pending(source_env: nil)
      # Omitting the key entirely skips env filtering (both rows).
      assert {:ok, both} = TriggerRequests.fetch_pending()
      assert length(both) == 2
    end

    test "respects limit", %{episode: episode} do
      ep2 = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
      {:ok, _} = create_trigger_request(episode)
      {:ok, _} = create_trigger_request(ep2)

      assert {:ok, fetched} = TriggerRequests.fetch_pending(limit: 1)
      assert length(fetched) == 1
    end

    test "does not return claimed requests", %{episode: episode} do
      {:ok, _} = create_trigger_request(episode)

      {:ok, [request]} = TriggerRequests.fetch_pending()
      TriggerRequests.mark_claimed(request.id, "node-a")

      assert {:ok, []} = TriggerRequests.fetch_pending()
    end
  end

  describe "mark_claimed/2" do
    test "marks a request as claimed", %{episode: episode} do
      {:ok, request} = create_trigger_request(episode)

      assert :ok = TriggerRequests.mark_claimed(request.id, "claimer-node")

      updated = Repo.get!(Cyclium.Schemas.TriggerRequest, request.id)
      assert updated.status == :claimed
      assert updated.claimed_by == "claimer-node"
      assert updated.claimed_at != nil
    end
  end

  describe "mark_completed/1" do
    test "marks a request as completed", %{episode: episode} do
      {:ok, request} = create_trigger_request(episode)
      TriggerRequests.mark_claimed(request.id, "node")

      assert :ok = TriggerRequests.mark_completed(request.id)

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

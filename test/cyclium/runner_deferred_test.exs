defmodule Cyclium.Runner.DeferredTest do
  use Cyclium.DataCase, async: false

  alias Cyclium.Runner.Deferred

  setup do
    Application.put_env(:cyclium, :mode, :trigger_only)
    Application.put_env(:cyclium, :stack_slug, :test_stack)
    start_supervised!(Cyclium.Mode)

    on_exit(fn ->
      Application.delete_env(:cyclium, :mode)
      Application.delete_env(:cyclium, :stack_slug)
    end)

    :ok
  end

  describe "enqueue/2" do
    test "creates a trigger request instead of running the episode" do
      episode = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})

      assert {:ok, request} = Deferred.enqueue(episode.id)
      assert request.episode_id == episode.id
      assert request.actor_id == "test_actor"
      assert request.expectation_id == "test_exp"
      assert request.source_stack == "test_stack"
      assert request.status == :pending
    end

    test "returns error for nonexistent episode" do
      assert {:error, :episode_not_found} = Deferred.enqueue(Ecto.UUID.generate())
    end

    test "passes opts through" do
      episode = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
      {:ok, request} = Deferred.enqueue(episode.id, resume: true)
      assert request.opts == %{resume: true}
    end
  end

  describe "recover_incomplete/0" do
    test "is a no-op" do
      assert :ok = Deferred.recover_incomplete()
    end
  end

  describe "cancel/1" do
    test "cancels the episode" do
      episode = insert_episode(%{actor_id: "test_actor", expectation_id: "test_exp"})
      assert :ok = Deferred.cancel(episode.id)

      updated = Repo.get!(Cyclium.Schemas.Episode, episode.id)
      assert updated.status == :canceled
    end
  end
end

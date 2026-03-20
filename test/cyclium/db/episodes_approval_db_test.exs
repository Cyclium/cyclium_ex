defmodule Cyclium.EpisodesApprovalDbTest do
  @moduledoc """
  Integration tests for interactive episode features:
  resolve_approval/3 and list_for_conversation/2.
  """
  use Cyclium.DataCase

  alias Cyclium.{Episodes, Conversations}
  alias Cyclium.Schemas.EpisodeStep

  setup do
    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    on_exit(fn ->
      Application.delete_env(:cyclium, :runner)
    end)

    :ok
  end

  defp start_conversation do
    {:ok, conv} =
      Conversations.start(%{
        actor_id: "approval_test_actor",
        name: "Approval Test"
      })

    conv
  end

  describe "resolve_approval/3" do
    test "approves a blocked episode with matching plan_hash" do
      conv = start_conversation()

      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :blocked,
          conversation_id: conv.id,
          trigger_type: :interactive
        })

      # Insert the approval_requested step with plan_hash
      Repo.insert!(%EpisodeStep{
        episode_id: episode.id,
        step_no: 1,
        kind: :approval_requested,
        args_redacted: %{"plan_hash" => "abc123"},
        created_at: DateTime.utc_now()
      })

      assert {:ok, :resumed} = Episodes.resolve_approval(episode.id, "abc123", true)

      updated = Episodes.get!(episode.id)
      assert updated.status == :running
    end

    test "denies a blocked episode" do
      conv = start_conversation()

      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :blocked,
          conversation_id: conv.id,
          trigger_type: :interactive
        })

      Repo.insert!(%EpisodeStep{
        episode_id: episode.id,
        step_no: 1,
        kind: :approval_requested,
        args_redacted: %{"plan_hash" => "abc123"},
        created_at: DateTime.utc_now()
      })

      assert {:ok, :denied} = Episodes.resolve_approval(episode.id, "abc123", false)

      updated = Episodes.get!(episode.id)
      assert updated.status == :canceled
    end

    test "rejects mismatched plan_hash" do
      conv = start_conversation()

      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :blocked,
          conversation_id: conv.id,
          trigger_type: :interactive
        })

      Repo.insert!(%EpisodeStep{
        episode_id: episode.id,
        step_no: 1,
        kind: :approval_requested,
        args_redacted: %{"plan_hash" => "abc123"},
        created_at: DateTime.utc_now()
      })

      assert {:error, :plan_hash_mismatch} =
               Episodes.resolve_approval(episode.id, "wrong_hash")
    end

    test "returns not_blocked for running episode" do
      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :running,
          trigger_type: :interactive
        })

      assert {:error, :not_blocked} = Episodes.resolve_approval(episode.id, "any_hash")
    end

    test "returns no_pending_approval when no approval step exists" do
      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :blocked,
          trigger_type: :interactive
        })

      assert {:error, :no_pending_approval} =
               Episodes.resolve_approval(episode.id, "any_hash")
    end

    test "journals approval_resolved step" do
      conv = start_conversation()

      episode =
        insert_episode(%{
          actor_id: "approval_test_actor",
          status: :blocked,
          conversation_id: conv.id,
          trigger_type: :interactive
        })

      Repo.insert!(%EpisodeStep{
        episode_id: episode.id,
        step_no: 1,
        kind: :approval_requested,
        args_redacted: %{"plan_hash" => "hash1"},
        created_at: DateTime.utc_now()
      })

      {:ok, :resumed} = Episodes.resolve_approval(episode.id, "hash1")

      steps = Episodes.list_steps(episode.id)
      assert length(steps) == 2
      resolved_step = Enum.find(steps, &(&1.kind == :approval_resolved))
      assert resolved_step.result_ref["approved"] == true
      assert resolved_step.result_ref["plan_hash"] == "hash1"
    end
  end

  describe "list_for_conversation/2" do
    test "returns episodes for a conversation ordered by start time" do
      conv = start_conversation()
      now = DateTime.utc_now()

      ep1 =
        insert_episode(%{
          actor_id: "approval_test_actor",
          conversation_id: conv.id,
          started_at: now,
          trigger_type: :interactive
        })

      ep2 =
        insert_episode(%{
          actor_id: "approval_test_actor",
          conversation_id: conv.id,
          started_at: DateTime.add(now, 5, :second),
          trigger_type: :interactive
        })

      # Unrelated episode
      insert_episode(%{actor_id: "other_actor"})

      results = Episodes.list_for_conversation(conv.id)
      ids = Enum.map(results, & &1.id)
      assert length(ids) == 2
      assert ids == [ep1.id, ep2.id]
    end

    test "returns empty list for no episodes" do
      assert [] == Episodes.list_for_conversation(Ecto.UUID.generate())
    end

    test "respects limit option" do
      conv = start_conversation()
      now = DateTime.utc_now()

      for i <- 1..5 do
        insert_episode(%{
          actor_id: "approval_test_actor",
          conversation_id: conv.id,
          started_at: DateTime.add(now, i, :second),
          trigger_type: :interactive
        })
      end

      assert length(Episodes.list_for_conversation(conv.id, limit: 3)) == 3
    end
  end
end

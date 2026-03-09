defmodule Cyclium.ConversationLifecycleDbTest do
  @moduledoc """
  Tests for conversation lifecycle edge cases and state transitions.
  """
  use Cyclium.DataCase

  alias Cyclium.Conversations
  alias Cyclium.Schemas.Conversation

  defp start_conversation(overrides \\ %{}) do
    defaults = %{
      actor_id: "lifecycle_actor",
      name: "Lifecycle Test",
      principal: %{"type" => "user", "id" => "user_1"}
    }

    {:ok, conv} = Conversations.start(Map.merge(defaults, overrides))
    conv
  end

  describe "terminal state transitions" do
    test "cannot resolve → resolve" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "done")
      assert {:error, :already_terminal} = Conversations.resolve(conv.id, "again")
    end

    test "cannot resolve → abandon" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "done")
      assert {:error, :already_terminal} = Conversations.abandon(conv.id)
    end

    test "cannot resolve → timeout" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "done")
      assert {:error, :already_terminal} = Conversations.timeout(conv.id)
    end

    test "cannot abandon → resolve" do
      conv = start_conversation()
      {:ok, _} = Conversations.abandon(conv.id)
      assert {:error, :already_terminal} = Conversations.resolve(conv.id, "done")
    end

    test "cannot abandon → abandon" do
      conv = start_conversation()
      {:ok, _} = Conversations.abandon(conv.id)
      assert {:error, :already_terminal} = Conversations.abandon(conv.id)
    end

    test "cannot timeout → resolve" do
      conv = start_conversation()
      {:ok, _} = Conversations.timeout(conv.id)
      assert {:error, :already_terminal} = Conversations.resolve(conv.id, "done")
    end

    test "cannot timeout → abandon" do
      conv = start_conversation()
      {:ok, _} = Conversations.timeout(conv.id)
      assert {:error, :already_terminal} = Conversations.abandon(conv.id)
    end

    test "cannot timeout → timeout" do
      conv = start_conversation()
      {:ok, _} = Conversations.timeout(conv.id)
      assert {:error, :already_terminal} = Conversations.timeout(conv.id)
    end
  end

  describe "claim edge cases" do
    test "claim sets principal on awaiting conversation" do
      conv =
        start_conversation(%{
          principal: nil,
          audience_target: %{"mode" => "pool"}
        })

      {:ok, claimed} = Conversations.claim(conv.id, %{"id" => "u2", "label" => "Bob"})
      assert claimed.status == "open"

      decoded = Conversation.decode_principal(claimed)
      assert decoded["id"] == "u2"
      assert decoded["label"] == "Bob"
    end

    test "second claim on same conversation fails" do
      conv =
        start_conversation(%{
          principal: nil,
          audience_target: %{"mode" => "pool"}
        })

      {:ok, _} = Conversations.claim(conv.id, %{"id" => "u2"})
      assert {:error, :already_claimed} = Conversations.claim(conv.id, %{"id" => "u3"})
    end

    test "can update principal on open conversation with no principal_id" do
      # Edge case: open conversation where principal has no "id" key
      {:ok, conv} =
        Conversations.start(%{
          actor_id: "lifecycle_actor",
          name: "No principal id",
          status: "open"
        })

      assert is_nil(conv.principal_id)

      {:ok, updated} = Conversations.claim(conv.id, %{"id" => "u1", "label" => "Alice"})
      assert updated.principal_id == "u1"
    end
  end

  describe "collected fields accumulation" do
    test "multiple updates merge correctly" do
      conv = start_conversation()

      {:ok, _} = Conversations.update_collected_fields(conv.id, %{"name" => "Alice"})
      {:ok, _} = Conversations.update_collected_fields(conv.id, %{"age" => 30})
      {:ok, updated} = Conversations.update_collected_fields(conv.id, %{"email" => "a@b.com"})

      fields = Conversation.decode_collected_fields(updated)
      assert fields["name"] == "Alice"
      assert fields["age"] == 30
      assert fields["email"] == "a@b.com"
    end

    test "later value overwrites earlier for same key" do
      conv = start_conversation()

      {:ok, _} = Conversations.update_collected_fields(conv.id, %{"name" => "Alice"})
      {:ok, updated} = Conversations.update_collected_fields(conv.id, %{"name" => "Bob"})

      assert Conversation.decode_collected_fields(updated)["name"] == "Bob"
    end
  end

  describe "constraint checking with multiple constraints" do
    test "token budget exceeded" do
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"max_total_tokens" => 1000}}
        })

      {:ok, _} = Conversations.increment_turn(conv.id, 500)
      {:ok, updated} = Conversations.increment_turn(conv.id, 600)

      assert {:error, :budget_exceeded} = Conversations.check_constraints(updated)
    end

    test "multiple constraints — turns exceeded first" do
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"max_turns" => 2, "max_total_tokens" => 100_000}}
        })

      {:ok, _} = Conversations.increment_turn(conv.id, 10)
      {:ok, updated} = Conversations.increment_turn(conv.id, 10)

      assert {:error, :budget_exceeded} = Conversations.check_constraints(updated)
    end

    test "timeout constraint" do
      # Create a conversation that started long ago
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"timeout_minutes" => 0}}
        })

      # timeout_minutes: 0 means it already expired
      assert {:error, :budget_exceeded} = Conversations.check_constraints(conv)
    end
  end

  describe "resolve with various outcomes" do
    test "stores outcome and result" do
      conv = start_conversation()
      result = %{"answer" => 42, "confidence" => 0.95}

      {:ok, resolved} = Conversations.resolve(conv.id, "success", result)

      assert resolved.resolved_outcome == "success"
      decoded = Conversation.decode_result(resolved)
      assert decoded["answer"] == 42
      assert decoded["confidence"] == 0.95
    end

    test "resolve with default empty result" do
      conv = start_conversation()
      {:ok, resolved} = Conversations.resolve(conv.id, "completed")

      decoded = Conversation.decode_result(resolved)
      assert decoded == %{}
    end
  end
end

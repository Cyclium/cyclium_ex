defmodule Cyclium.ConversationsDbTest do
  @moduledoc """
  Integration tests for Cyclium.Conversations against the SQLite sandbox.
  """
  use Cyclium.DataCase

  alias Cyclium.Conversations
  alias Cyclium.Schemas.Conversation

  defp start_conversation(overrides \\ %{}) do
    defaults = %{
      actor_id: "test_interactive_actor",
      name: "Test Conversation",
      principal: %{"type" => "user", "id" => "user_1", "label" => "Alice"}
    }

    {:ok, conv} = Conversations.start(Map.merge(defaults, overrides))
    conv
  end

  describe "start/1" do
    test "creates an open conversation for user-initiated" do
      conv =
        start_conversation(%{
          principal: %{"type" => "user", "id" => "user_1", "label" => "Alice"}
        })

      assert conv.status == "open"
      assert conv.actor_id == "test_interactive_actor"
      assert conv.principal_id == "user_1"
      assert conv.turns_used == 0
      assert conv.tokens_used == 0
    end

    test "creates awaiting_participant for pool audience" do
      conv =
        start_conversation(%{
          principal: nil,
          audience_target: %{"mode" => "pool", "pool" => "support_team"}
        })

      assert conv.status == "awaiting_participant"
    end

    test "creates awaiting_participant for principal audience without principal id" do
      conv =
        start_conversation(%{
          principal: nil,
          audience_target: %{"mode" => "principal", "principal_id" => "user_2"}
        })

      assert conv.status == "awaiting_participant"
    end

    test "stores goal as JSON" do
      goal = %{
        "type" => "collect_info",
        "description" => "Gather user details",
        "constraints" => %{"max_turns" => 10}
      }

      conv = start_conversation(%{goal: goal})
      decoded = Conversation.decode_goal(conv)

      assert decoded["type"] == "collect_info"
      assert decoded["constraints"]["max_turns"] == 10
    end

    test "stores expectation_id when provided" do
      conv = start_conversation(%{expectation_id: :deep_review})
      assert Cyclium.Conversations.get!(conv.id).expectation_id == "deep_review"
    end

    test "leaves expectation_id nil by default" do
      conv = start_conversation()
      assert conv.expectation_id == nil
    end

    test "stores origin as JSON" do
      conv =
        start_conversation(%{
          origin: %{"type" => "workflow", "workflow_ref" => %{"id" => "wf_1"}}
        })

      decoded = Conversation.decode_origin(conv)
      assert decoded["type"] == "workflow"
    end

    test "generates default name when not provided" do
      {:ok, conv} = Conversations.start(%{actor_id: "a"})
      assert conv.name =~ "Conversation"
    end
  end

  describe "claim/2" do
    test "claims an awaiting_participant conversation" do
      conv =
        start_conversation(%{
          principal: nil,
          audience_target: %{"mode" => "pool"}
        })

      assert conv.status == "awaiting_participant"

      {:ok, claimed} = Conversations.claim(conv.id, %{"id" => "user_2", "label" => "Bob"})

      assert claimed.status == "open"
      assert claimed.principal_id == "user_2"
    end

    test "returns already_claimed when principal already set" do
      conv = start_conversation()
      assert conv.principal_id == "user_1"

      assert {:error, :already_claimed} =
               Conversations.claim(conv.id, %{"id" => "user_3"})
    end

    test "returns not_found for missing conversation" do
      assert {:error, :not_found} =
               Conversations.claim(Ecto.UUID.generate(), %{"id" => "x"})
    end
  end

  describe "resolve/3" do
    test "resolves an open conversation" do
      conv = start_conversation()

      {:ok, resolved} = Conversations.resolve(conv.id, "completed", %{"summary" => "done"})

      assert resolved.status == "resolved"
      assert resolved.resolved_outcome == "completed"
      assert Conversation.decode_result(resolved)["summary"] == "done"
    end

    test "returns already_terminal for resolved conversation" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "completed")

      assert {:error, :already_terminal} = Conversations.resolve(conv.id, "again")
    end

    test "returns not_found for missing id" do
      assert {:error, :not_found} = Conversations.resolve(Ecto.UUID.generate(), "done")
    end
  end

  describe "abandon/2" do
    test "abandons an open conversation" do
      conv = start_conversation()

      {:ok, abandoned} = Conversations.abandon(conv.id, "user left")

      assert abandoned.status == "abandoned"
      assert Conversation.decode_result(abandoned)["reason"] == "user left"
    end

    test "cannot abandon already-resolved conversation" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "completed")

      assert {:error, :already_terminal} = Conversations.abandon(conv.id, "too late")
    end
  end

  describe "timeout/1" do
    test "times out an open conversation" do
      conv = start_conversation()

      {:ok, timed_out} = Conversations.timeout(conv.id)
      assert timed_out.status == "timed_out"
    end

    test "cannot timeout already-abandoned conversation" do
      conv = start_conversation()
      {:ok, _} = Conversations.abandon(conv.id)

      assert {:error, :already_terminal} = Conversations.timeout(conv.id)
    end
  end

  describe "increment_turn/2" do
    test "increments turn and token counters" do
      conv = start_conversation()

      {:ok, updated} = Conversations.increment_turn(conv.id, 150)
      assert updated.turns_used == 1
      assert updated.tokens_used == 150

      {:ok, updated2} = Conversations.increment_turn(conv.id, 200)
      assert updated2.turns_used == 2
      assert updated2.tokens_used == 350
    end
  end

  describe "update_collected_fields/2" do
    test "merges fields into existing map" do
      conv = start_conversation()

      {:ok, _} = Conversations.update_collected_fields(conv.id, %{"name" => "Alice"})
      {:ok, updated} = Conversations.update_collected_fields(conv.id, %{"email" => "a@b.com"})

      fields = Conversation.decode_collected_fields(updated)
      assert fields["name"] == "Alice"
      assert fields["email"] == "a@b.com"
    end

    test "overwrites same key" do
      conv = start_conversation()

      {:ok, _} = Conversations.update_collected_fields(conv.id, %{"name" => "Alice"})
      {:ok, updated} = Conversations.update_collected_fields(conv.id, %{"name" => "Bob"})

      assert Conversation.decode_collected_fields(updated)["name"] == "Bob"
    end
  end

  describe "check_constraints/1" do
    test "returns ok when no constraints" do
      conv = start_conversation()
      assert :ok = Conversations.check_constraints(conv)
    end

    test "returns budget_exceeded when max_turns reached" do
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"max_turns" => 3}}
        })

      {:ok, _} = Conversations.increment_turn(conv.id)
      {:ok, _} = Conversations.increment_turn(conv.id)
      {:ok, updated} = Conversations.increment_turn(conv.id)

      assert {:error, :budget_exceeded} = Conversations.check_constraints(updated)
    end

    test "returns last_turn warning when one turn remaining" do
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"max_turns" => 3}}
        })

      {:ok, _} = Conversations.increment_turn(conv.id)
      {:ok, updated} = Conversations.increment_turn(conv.id)

      assert {:warn, :last_turn} = Conversations.check_constraints(updated)
    end

    test "returns budget_exceeded when max_tokens reached" do
      conv =
        start_conversation(%{
          goal: %{"constraints" => %{"max_total_tokens" => 500}}
        })

      {:ok, updated} = Conversations.increment_turn(conv.id, 600)

      assert {:error, :budget_exceeded} = Conversations.check_constraints(updated)
    end
  end

  describe "query helpers" do
    test "get/1 returns conversation" do
      conv = start_conversation()
      assert Conversations.get(conv.id).id == conv.id
    end

    test "get/1 returns nil for missing" do
      assert is_nil(Conversations.get(Ecto.UUID.generate()))
    end

    test "list_for_principal/2 returns conversations for principal" do
      start_conversation(%{principal: %{"id" => "principal_a"}})
      start_conversation(%{principal: %{"id" => "principal_a"}})
      start_conversation(%{principal: %{"id" => "principal_b"}})

      results = Conversations.list_for_principal("principal_a")
      assert length(results) == 2
    end

    test "list_for_principal/2 filters by status" do
      c1 = start_conversation(%{principal: %{"id" => "p1"}})
      start_conversation(%{principal: %{"id" => "p1"}})

      Conversations.resolve(c1.id, "done")

      open = Conversations.list_for_principal("p1", status: "open")
      assert length(open) == 1

      resolved = Conversations.list_for_principal("p1", status: "resolved")
      assert length(resolved) == 1
    end

    test "list_awaiting/1 returns awaiting conversations" do
      start_conversation(%{
        principal: nil,
        audience_target: %{"mode" => "pool"}
      })

      start_conversation()

      awaiting = Conversations.list_awaiting()
      assert length(awaiting) == 1
      assert hd(awaiting).status == "awaiting_participant"
    end

    test "list_awaiting/1 filters by actor_id" do
      start_conversation(%{
        actor_id: "actor_a",
        principal: nil,
        audience_target: %{"mode" => "pool"}
      })

      start_conversation(%{
        actor_id: "actor_b",
        principal: nil,
        audience_target: %{"mode" => "pool"}
      })

      assert length(Conversations.list_awaiting(actor_id: "actor_a")) == 1
    end

    test "list_for_actor/2 returns conversations for actor" do
      start_conversation(%{actor_id: "special_actor"})
      start_conversation(%{actor_id: "special_actor"})
      start_conversation(%{actor_id: "other_actor"})

      results = Conversations.list_for_actor("special_actor")
      assert length(results) == 2
    end
  end
end

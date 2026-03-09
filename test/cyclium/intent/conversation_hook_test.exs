defmodule Cyclium.Intent.ConversationHookTest do
  @moduledoc """
  Integration tests for ConversationHook post-converge behaviour.
  """
  use Cyclium.DataCase

  alias Cyclium.{Conversations, ConvergeResult}
  alias Cyclium.Intent.ConversationHook
  alias Cyclium.Schemas.Conversation

  defp start_conversation(overrides \\ %{}) do
    defaults = %{
      actor_id: "hook_test_actor",
      name: "Hook Test",
      principal: %{"type" => "user", "id" => "user_1"}
    }

    {:ok, conv} = Conversations.start(Map.merge(defaults, overrides))
    conv
  end

  defp converge_result(overrides \\ %{}) do
    struct!(ConvergeResult, overrides)
  end

  describe "after_converge/3" do
    test "increments turn counter" do
      conv = start_conversation()

      ConversationHook.after_converge(conv.id, converge_result(), 100)

      updated = Conversations.get!(conv.id)
      assert updated.turns_used == 1
      assert updated.tokens_used == 100
    end

    test "updates collected fields from classification" do
      conv = start_conversation()

      result =
        converge_result(%{
          classification: %{"collected_fields" => %{"name" => "Alice"}}
        })

      ConversationHook.after_converge(conv.id, result)

      updated = Conversations.get!(conv.id)
      assert Conversation.decode_collected_fields(updated)["name"] == "Alice"
    end

    test "resolves conversation when goal evaluator signals resolution" do
      conv =
        start_conversation(%{
          goal: %{
            "type" => "assist",
            "completion_criteria" => %{"mode" => "strategy_decides"}
          }
        })

      result =
        converge_result(%{
          classification: %{
            "conversation_resolved" => true,
            "outcome" => "completed",
            "result" => %{"answer" => "42"}
          }
        })

      ConversationHook.after_converge(conv.id, result)

      updated = Conversations.get!(conv.id)
      assert updated.status == "resolved"
      assert updated.resolved_outcome == "completed"
    end

    test "abandons conversation when goal evaluator signals abandonment" do
      conv =
        start_conversation(%{
          goal: %{
            "type" => "assist",
            "completion_criteria" => %{"mode" => "strategy_decides"}
          }
        })

      result =
        converge_result(%{
          classification: %{
            "conversation_abandoned" => true,
            "reason" => "off topic"
          }
        })

      ConversationHook.after_converge(conv.id, result)

      updated = Conversations.get!(conv.id)
      assert updated.status == "abandoned"
    end

    test "times out conversation when budget exceeded" do
      conv =
        start_conversation(%{
          goal: %{
            "type" => "assist",
            "constraints" => %{"max_turns" => 1},
            "completion_criteria" => %{"mode" => "strategy_decides"}
          }
        })

      ConversationHook.after_converge(conv.id, converge_result())

      updated = Conversations.get!(conv.id)
      assert updated.status == "timed_out"
    end

    test "no-ops for already-resolved conversation" do
      conv = start_conversation()
      {:ok, _} = Conversations.resolve(conv.id, "done")

      # Should not error
      assert :ok = ConversationHook.after_converge(conv.id, converge_result())
    end

    test "no-ops for missing conversation" do
      assert :ok = ConversationHook.after_converge(Ecto.UUID.generate(), converge_result())
    end

    test "resolves via required_fields when all fields collected" do
      conv =
        start_conversation(%{
          goal: %{
            "type" => "collect_info",
            "completion_criteria" => %{
              "mode" => "required_fields",
              "fields" => [
                %{"key" => "name", "required" => true},
                %{"key" => "email", "required" => true}
              ]
            }
          }
        })

      # Turn 1: collect name
      r1 = converge_result(%{classification: %{"collected_fields" => %{"name" => "Alice"}}})
      ConversationHook.after_converge(conv.id, r1)
      assert Conversations.get!(conv.id).status == "open"

      # Turn 2: collect email -> should resolve
      r2 = converge_result(%{classification: %{"collected_fields" => %{"email" => "a@b.com"}}})
      ConversationHook.after_converge(conv.id, r2)

      updated = Conversations.get!(conv.id)
      assert updated.status == "resolved"
      assert updated.resolved_outcome == "completed"
    end
  end
end

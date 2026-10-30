defmodule Cyclium.ApprovalResumeGateDbTest do
  @moduledoc """
  A plan rebuilt from the journal after a human approves it goes back through
  the gate. A model-authored `request_approval` can never become an executed
  plan, and a journal entry that was gated once is gated again on resume.
  """
  use Cyclium.DataCase

  alias Cyclium.{Conversations, Episodes}
  alias Cyclium.Strategy.Template.Interactive
  alias Cyclium.Schemas.EpisodeStep

  @actor_id "approval_gate_actor"

  setup do
    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)
    on_exit(fn -> Application.delete_env(:cyclium, :runner) end)
    :ok
  end

  defp blocked_episode do
    {:ok, conv} = Conversations.start(%{actor_id: @actor_id, name: "gate"})

    insert_episode(%{
      actor_id: @actor_id,
      status: :blocked,
      conversation_id: conv.id,
      trigger_type: :interactive
    })
  end

  defp journal(episode, kind, step_no, attrs) do
    Repo.insert!(
      struct(
        EpisodeStep,
        Map.merge(
          %{episode_id: episode.id, step_no: step_no, kind: kind, created_at: DateTime.utc_now()},
          attrs
        )
      )
    )
  end

  defp state(episode) do
    %{
      phase: :context_assembly,
      strategy_config: %{
        "allowed_tool_signatures" => [
          %{"name" => "lookup_user", "side_effect" => "read", "actions" => [%{"name" => "get"}]}
        ]
      },
      message: "hi",
      principal: nil,
      history: [],
      conversation_id: episode.conversation_id,
      conversation: nil,
      goal: nil,
      gathered_context: nil,
      action_plan: nil,
      plan_hash: nil,
      execution_results: [],
      current_step_index: 0,
      deny_reason: nil,
      explanation: nil
    }
  end

  defp plan_json(tool, action) do
    %{
      "kind" => "tool_call",
      "risk" => "low",
      "why" => "x",
      "tool" => %{"tool" => tool, "action" => action, "args" => %{}}
    }
  end

  test "an approved preview plan resumes into :validate and only executes if it still passes" do
    episode = blocked_episode()

    journal(episode, :approval_requested, 1, %{
      args_redacted: %{
        "source" => "preview",
        "plan_hash" => "h",
        "plan" => plan_json("lookup_user", "get")
      }
    })

    journal(episode, :approval_resolved, 2, %{
      result_ref: %{"approved" => true, "plan_hash" => "h"}
    })

    {:ok, resumed} = Interactive.resume_from_block(state(episode), episode)
    assert resumed.phase == :validate
    assert resumed.approved_from_journal

    # Passes the gate: executes without a second preview.
    assert {:observe, %{validated: true, next_phase: :execute}} =
             Interactive.next_step(resumed, %{})
  end

  describe "context a resumed plan's summarize step carries" do
    defp approved_episode_with_history do
      episode = blocked_episode()

      insert_episode(%{
        actor_id: @actor_id,
        status: :done,
        conversation_id: episode.conversation_id,
        trigger_type: :interactive,
        summary: "294 matches.",
        started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      journal(episode, :approval_requested, 1, %{
        args_redacted: %{
          "source" => "preview",
          "plan_hash" => "h",
          "plan" => plan_json("lookup_user", "get")
        }
      })

      journal(episode, :approval_resolved, 2, %{
        result_ref: %{"approved" => true, "plan_hash" => "h"}
      })

      episode
    end

    test "is assembled again on resume, with the conversation history" do
      episode = approved_episode_with_history()

      {:ok, resumed} = Interactive.resume_from_block(state(episode), episode)
      assert [%{role: "assistant", content: "294 matches."}] = resumed.gathered_context.history

      summarizing = %{
        resumed
        | phase: :summarize,
          execution_results: [{:ok, %{rows: []}}]
      }

      assert {:synthesize, %{context: %{history: [%{content: "294 matches."}]}}} =
               Interactive.next_step(summarizing, %{})
    end

    test "is assembled again for an AgenticTask too" do
      episode = approved_episode_with_history()

      state = %{
        phase: :context_assembly,
        strategy_config: %{"summarize_context" => [:findings]},
        message: "review it",
        payload: %{},
        gathered_context: nil,
        action_plan: nil,
        plan_hash: nil,
        execution_results: [],
        current_step_index: 0,
        deny_reason: nil,
        explanation: nil,
        conclusion: nil,
        budget_exhausted: false
      }

      {:ok, resumed} = Cyclium.Strategy.Template.AgenticTask.resume_from_block(state, episode)
      assert %{findings: [], objective: "review it"} = resumed.gathered_context
    end

    test "leaves out turns sent while the plan waited for approval" do
      episode = approved_episode_with_history()

      insert_episode(%{
        actor_id: @actor_id,
        status: :done,
        conversation_id: episode.conversation_id,
        trigger_type: :interactive,
        summary: "a later turn",
        started_at: DateTime.add(episode.started_at, 30, :second)
      })

      {:ok, resumed} = Interactive.resume_from_block(state(episode), episode)
      assert Enum.map(resumed.gathered_context.history, & &1.content) == ["294 matches."]
    end

    test "is not assembled for a denied plan" do
      episode = blocked_episode()

      journal(episode, :approval_requested, 1, %{
        args_redacted: %{
          "source" => "preview",
          "plan_hash" => "h",
          "plan" => plan_json("lookup_user", "get")
        }
      })

      journal(episode, :approval_resolved, 2, %{
        result_ref: %{"approved" => false, "plan_hash" => "h"}
      })

      {:ok, resumed} = Interactive.resume_from_block(state(episode), episode)
      assert resumed.phase == :denied
      assert resumed.gathered_context == nil
    end
  end

  test "an approved journal plan that no longer passes the gate is denied, not executed" do
    episode = blocked_episode()

    # The journal says the human approved a call the current signatures do not allow.
    journal(episode, :approval_requested, 1, %{
      args_redacted: %{
        "source" => "preview",
        "plan_hash" => "h",
        "plan" => plan_json("lookup_user", "purge")
      }
    })

    journal(episode, :approval_resolved, 2, %{
      result_ref: %{"approved" => true, "plan_hash" => "h"}
    })

    {:ok, resumed} = Interactive.resume_from_block(state(episode), episode)
    assert resumed.phase == :validate
    assert {:observe, %{denied: true, reason: reason}} = Interactive.next_step(resumed, %{})
    assert reason =~ ~s(action "purge")
  end

  test "a model-authored request_approval entry is never rebuilt into a plan" do
    episode = blocked_episode()

    # What the loop journals for a `request_approval` plan whose `approval` map
    # smuggled a plan_hash/plan pair: nested under "request", tagged by source.
    journal(episode, :approval_requested, 1, %{
      args_redacted: %{
        "source" => "request_approval",
        "request" => %{"plan_hash" => "h", "plan" => plan_json("lookup_user", "get")},
        "plan_hash" => "h",
        "plan" => plan_json("lookup_user", "get")
      }
    })

    journal(episode, :approval_resolved, 2, %{
      result_ref: %{"approved" => true, "plan_hash" => "h"}
    })

    fresh = state(episode)
    assert {:ok, ^fresh} = Interactive.resume_from_block(fresh, episode)
  end

  test "resolve_approval refuses a step that journaled no plan_hash" do
    episode = blocked_episode()
    journal(episode, :approval_requested, 1, %{args_redacted: nil})

    assert {:error, :no_plan_hash} = Episodes.resolve_approval(episode.id, "anything", true)
    assert Episodes.get!(episode.id).status == :blocked
  end

  test "resolve_approval checks the approver against the conversation's principal" do
    {:ok, conv} =
      Conversations.start(%{
        actor_id: @actor_id,
        name: "owned",
        principal: %{"type" => "user", "id" => "owner"}
      })

    episode =
      insert_episode(%{
        actor_id: @actor_id,
        status: :blocked,
        conversation_id: conv.id,
        trigger_type: :interactive
      })

    journal(episode, :approval_requested, 1, %{args_redacted: %{"plan_hash" => "h"}})

    assert {:error, :forbidden} =
             Episodes.resolve_approval(episode.id, "h", true,
               principal: %{"type" => "user", "id" => "intruder"}
             )

    assert {:ok, :resumed} =
             Episodes.resolve_approval(episode.id, "h", true,
               principal: %{"type" => "user", "id" => "owner"}
             )
  end
end

defmodule Cyclium.Strategy.Template.InteractiveTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.Interactive
  alias Cyclium.Intent.{ActionPlan, ToolCallStep}
  alias Cyclium.ConvergeResult

  # --- State factory ---

  defp base_state(overrides) do
    Map.merge(
      %{
        phase: :context_assembly,
        strategy_config: %{
          "allowed_tool_signatures" => [
            %{"name" => "lookup_user", "side_effect" => "read"},
            %{"name" => "update_user", "side_effect" => "write"}
          ]
        },
        message: "hello",
        principal: %{"id" => "user_1"},
        history: [],
        conversation_id: "conv_1",
        conversation: nil,
        goal: nil,
        gathered_context: nil,
        action_plan: nil,
        plan_hash: nil,
        execution_results: [],
        current_step_index: 0,
        deny_reason: nil,
        explanation: nil
      },
      overrides
    )
  end

  defp tool_call_plan(tool \\ "lookup_user", args \\ %{}) do
    %ActionPlan{
      kind: :tool_call,
      risk: :low,
      why: "test",
      tool: %ToolCallStep{tool: tool, action: "get", args: args}
    }
  end

  defp multi_tool_plan(n) do
    steps = for i <- 1..n, do: %ToolCallStep{tool: "lookup_user", action: "step#{i}", args: %{}}

    %ActionPlan{kind: :multi_tool_plan, risk: :low, why: "test", steps: steps}
  end

  # --- next_step ---

  describe "next_step/2 phase routing" do
    test "context_assembly emits :observe" do
      state = base_state(%{phase: :context_assembly})
      assert {:observe, context} = Interactive.next_step(state, %{actor_id: "a"})
      assert context.message == "hello"
    end

    test "interpret emits :synthesize" do
      state = base_state(%{phase: :interpret, gathered_context: %{data: true}})
      assert {:synthesize, prompt} = Interactive.next_step(state, %{})
      assert prompt.task == :interpret_intent
    end

    test "validate dispatches through PlanGate and transitions to execute on ok" do
      state =
        base_state(%{
          phase: :validate,
          action_plan: %ActionPlan{kind: :explain_only, risk: :low, why: "test"}
        })

      assert {:observe, %{validated: true, next_phase: :execute}} =
               Interactive.next_step(state, %{})
    end

    test "validate returns denied observation on plan gate rejection" do
      # Unknown tool — not in signatures
      plan = tool_call_plan("nuke_everything")

      state = base_state(%{phase: :validate, action_plan: plan})

      assert {:observe, %{denied: true, reason: reason}} = Interactive.next_step(state, %{})
      assert reason =~ "not in allowed signatures"
    end

    test "validate routes to preview when side effects and preview required" do
      plan = tool_call_plan("update_user")

      state =
        base_state(%{
          phase: :validate,
          action_plan: plan,
          strategy_config: %{
            "allowed_tool_signatures" => [
              %{"name" => "update_user", "side_effect" => "write"}
            ],
            "require_preview_for_side_effects" => true
          }
        })

      assert {:observe, %{validated: true, next_phase: :preview}} =
               Interactive.next_step(state, %{})
    end

    test "preview emits :approval with plan_hash" do
      state =
        base_state(%{
          phase: :preview,
          action_plan: tool_call_plan(),
          plan_hash: "12345"
        })

      assert {:approval, %{plan_hash: "12345"}} = Interactive.next_step(state, %{})
    end

    test "execute dispatches :tool_call for tool_call plan" do
      state = base_state(%{phase: :execute, action_plan: tool_call_plan()})

      assert {:tool_call, :lookup_user, :get, %{}} = Interactive.next_step(state, %{})
    end

    test "execute dispatches :tool_call for multi_tool_plan at current index" do
      plan = multi_tool_plan(3)
      state = base_state(%{phase: :execute, action_plan: plan, current_step_index: 1})

      assert {:tool_call, :lookup_user, :step2, %{}} = Interactive.next_step(state, %{})
    end

    test "execute dispatches :output for output_proposal plan" do
      output = %Cyclium.OutputProposal{
        type: :email,
        dedupe_key: "dk1",
        payload: %{"to" => "user"},
        requires_approval: false
      }

      plan = %ActionPlan{kind: :output_proposal, risk: :low, why: "test", output: output}
      state = base_state(%{phase: :execute, action_plan: plan})

      assert {:output, :email, %{"to" => "user"}} = Interactive.next_step(state, %{})
    end

    test "execute returns :converge for explain_only plan" do
      plan = %ActionPlan{kind: :explain_only, risk: :low, why: "test", explanation: "here you go"}
      state = base_state(%{phase: :execute, action_plan: plan})

      assert :converge = Interactive.next_step(state, %{})
    end

    test "execute dispatches :approval for request_approval plan" do
      plan = %ActionPlan{
        kind: :request_approval,
        risk: :high,
        why: "test",
        approval: %{description: "delete account"}
      }

      state = base_state(%{phase: :execute, action_plan: plan})

      assert {:approval, %{description: "delete account"}} = Interactive.next_step(state, %{})
    end

    test "summarize emits :synthesize" do
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{data: "result"}}]
        })

      assert {:synthesize, prompt} = Interactive.next_step(state, %{})
      assert prompt.task == :summarize_results
    end

    test "denied phase returns :converge" do
      assert :converge = Interactive.next_step(base_state(%{phase: :denied}), %{})
    end

    test "done phase returns :converge" do
      assert :converge = Interactive.next_step(base_state(%{phase: :done}), %{})
    end
  end

  # --- handle_result ---

  describe "handle_result/3 state transitions" do
    test "context_assembly → interpret" do
      state = base_state(%{phase: :context_assembly})

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{data: true}})
      assert new.phase == :interpret
      assert new.gathered_context == %{data: true}
    end

    test "interpret success → validate with parsed plan" do
      state = base_state(%{phase: :interpret})

      raw_plan = %{
        "kind" => "tool_call",
        "risk" => "low",
        "why" => "look up info",
        "tool" => %{"tool" => "lookup_user", "action" => "get", "args" => %{"id" => 1}}
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw_plan})
      assert new.phase == :validate
      assert new.action_plan.kind == :tool_call
      assert new.action_plan.tool.tool == "lookup_user"
      assert is_binary(new.plan_hash)
    end

    test "interpret success with explain_only" do
      state = base_state(%{phase: :interpret})

      raw = %{
        "kind" => "explain_only",
        "risk" => "low",
        "why" => "just explaining",
        "explanation" => "here's the answer"
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :validate
      assert new.action_plan.kind == :explain_only
      assert new.action_plan.explanation == "here's the answer"
    end

    test "interpret with unparseable result transitions to done" do
      state = base_state(%{phase: :interpret})

      # A map that triggers a parse error (e.g. missing enforce_keys for ToolCallStep)
      raw = %{"kind" => "tool_call", "risk" => "low", "why" => "test", "tool" => "not_a_map"}

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :done
      assert new.explanation =~ "Failed to interpret"
    end

    test "validate denied → denied phase" do
      state = base_state(%{phase: :validate})

      {:ok, new} =
        Interactive.handle_result(state, %{}, {:ok, %{denied: true, reason: "not allowed"}})

      assert new.phase == :denied
      assert new.deny_reason == "not allowed"
    end

    test "validate ok → execute" do
      state = base_state(%{phase: :validate})

      {:ok, new} =
        Interactive.handle_result(state, %{}, {:ok, %{validated: true, next_phase: :execute}})

      assert new.phase == :execute
      assert new.current_step_index == 0
    end

    test "validate ok → preview" do
      state = base_state(%{phase: :validate})

      {:ok, new} =
        Interactive.handle_result(state, %{}, {:ok, %{validated: true, next_phase: :preview}})

      assert new.phase == :preview
    end

    test "preview approved → execute" do
      state = base_state(%{phase: :preview})

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{approved: true}})
      assert new.phase == :execute
    end

    test "preview denied → denied" do
      state = base_state(%{phase: :preview})

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{approved: false}})
      assert new.phase == :denied
      assert new.deny_reason == "Plan rejected by user"
    end

    test "execute tool_call → summarize after completion" do
      state =
        base_state(%{
          phase: :execute,
          action_plan: tool_call_plan(),
          current_step_index: 0
        })

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{user: "Alice"}})
      assert new.phase == :summarize
      assert length(new.execution_results) == 1
    end

    test "execute multi_tool_plan advances step index" do
      plan = multi_tool_plan(3)

      state =
        base_state(%{
          phase: :execute,
          action_plan: plan,
          current_step_index: 0,
          execution_results: []
        })

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{data: 1}})
      assert new.phase == :execute
      assert new.current_step_index == 1
    end

    test "execute multi_tool_plan last step → summarize" do
      plan = multi_tool_plan(2)

      state =
        base_state(%{
          phase: :execute,
          action_plan: plan,
          current_step_index: 1,
          execution_results: [{:ok, %{data: 1}}]
        })

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, %{data: 2}})
      assert new.phase == :summarize
    end

    test "execute output_proposal → done" do
      plan = %ActionPlan{
        kind: :output_proposal,
        risk: :low,
        why: "test",
        output: %Cyclium.OutputProposal{
          type: :email,
          dedupe_key: "dk1",
          payload: %{},
          requires_approval: false
        }
      }

      state = base_state(%{phase: :execute, action_plan: plan})

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, :delivered})
      assert new.phase == :done
    end

    test "summarize with explain_only result → done" do
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{}}]
        })

      raw = %{
        "kind" => "explain_only",
        "risk" => "low",
        "why" => "summary",
        "explanation" => "Here's what happened"
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :done
      assert new.explanation == "Here's what happened"
    end

    test "summarize with follow-up tool_call loops back to validate" do
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{}}]
        })

      raw = %{
        "kind" => "tool_call",
        "risk" => "low",
        "why" => "need more data",
        "tool" => %{"tool" => "lookup_user", "action" => "get", "args" => %{}}
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :validate
      assert new.action_plan.kind == :tool_call
    end

    test "summarize error falls back to done" do
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{}}]
        })

      {:ok, new} = Interactive.handle_result(state, %{}, {:error, :timeout})
      assert new.phase == :done
    end
  end

  # --- converge ---

  describe "converge/2" do
    test "denied plan produces denial summary" do
      state = base_state(%{phase: :denied, deny_reason: "not allowed", action_plan: nil})

      {:ok, %ConvergeResult{} = result} = Interactive.converge(state, %{})
      assert result.summary =~ "denied"
      assert result.classification["primary"] == "denied"
    end

    test "explain_only produces explanation summary" do
      plan = %ActionPlan{
        kind: :explain_only,
        risk: :low,
        why: "test",
        explanation: "The answer is 42",
        meta: %{}
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.summary == "The answer is 42"
      assert result.classification["primary"] == "explain_only"
    end

    test "tool_call uses execution summary" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "test",
        tool: %ToolCallStep{tool: "lookup_user", action: "get", args: %{}},
        meta: %{}
      }

      state =
        base_state(%{
          phase: :done,
          action_plan: plan,
          execution_results: [{:ok, %{name: "Alice"}}]
        })

      {:ok, result} = Interactive.converge(state, %{})
      assert result.summary =~ "lookup_user"
      assert result.classification["primary"] == "tool_call"
    end

    test "propagates resolve_conversation meta to classification" do
      plan = %ActionPlan{
        kind: :explain_only,
        risk: :low,
        why: "test",
        explanation: "done",
        meta: %{
          "resolve_conversation" => true,
          "outcome" => "completed",
          "result" => %{"answer" => "42"}
        }
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.classification["conversation_resolved"] == true
      assert result.classification["outcome"] == "completed"
      assert result.classification["result"]["answer"] == "42"
    end

    test "propagates collected_fields meta to classification" do
      plan = %ActionPlan{
        kind: :explain_only,
        risk: :low,
        why: "test",
        explanation: "got it",
        meta: %{"collected_fields" => %{"name" => "Alice"}}
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.classification["collected_fields"]["name"] == "Alice"
    end

    test "output_proposal includes output in converge result" do
      output = %Cyclium.OutputProposal{
        type: :email,
        dedupe_key: "dk1",
        payload: %{"to" => "user"},
        requires_approval: false
      }

      plan = %ActionPlan{
        kind: :output_proposal,
        risk: :low,
        why: "test",
        output: output,
        meta: %{}
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert length(result.outputs) == 1
    end

    test "findings from meta are extracted" do
      plan = %ActionPlan{
        kind: :explain_only,
        risk: :low,
        why: "test",
        explanation: "found issue",
        meta: %{
          "findings" => [
            %{"action" => "raise", "class" => "anomaly", "summary" => "unusual"},
            %{"action" => "clear", "key" => "old_finding", "reason" => "resolved"}
          ]
        }
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert length(result.findings) == 2
      assert {:raise, _} = hd(result.findings)
    end

    test "no plan produces no_action classification" do
      state = base_state(%{phase: :done, action_plan: nil, explanation: "nothing to do"})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.classification["primary"] == "no_action"
    end

    test "workflow_result includes conversation_id" do
      plan = %ActionPlan{kind: :explain_only, risk: :low, why: "test", meta: %{}}
      state = base_state(%{phase: :done, action_plan: plan, conversation_id: "conv_123"})

      {:ok, converge_result} = Interactive.converge(state, %{})
      wf_result = Interactive.workflow_result(state, converge_result)

      assert wf_result.conversation_id == "conv_123"
    end
  end
end

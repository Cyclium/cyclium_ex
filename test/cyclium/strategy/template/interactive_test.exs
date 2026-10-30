defmodule Cyclium.Strategy.Template.InteractiveTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.Agentic.Loop
  alias Cyclium.Strategy.Template.Interactive
  alias Cyclium.Intent.{ActionPlan, ToolCallStep}
  alias Cyclium.ConvergeResult

  # The loop dispatches a validated call through existing atoms only (a tool
  # name with no atom has no registered capability). These are the tool and
  # action names the plans below use, as compile-time atoms.
  def __tool_atoms__, do: [:lookup_user, :update_user, :get, :step1, :step2, :step3]

  # --- State factory ---

  defp base_state(overrides) do
    Map.merge(
      %{
        phase: :context_assembly,
        strategy_config: %{
          "allowed_tool_signatures" => [
            %{
              "name" => "lookup_user",
              "side_effect" => "read",
              "actions" => [
                %{"name" => "get"},
                %{"name" => "step1"},
                %{"name" => "step2"},
                %{"name" => "step3"}
              ]
            },
            %{
              "name" => "update_user",
              "side_effect" => "write",
              "actions" => [%{"name" => "get"}]
            }
          ],
          "allowed_output_types" => ["email"]
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

  defp summarize_state(gathered_context) do
    base_state(%{
      phase: :summarize,
      action_plan: tool_call_plan(),
      execution_results: [{:ok, %{data: "result"}}],
      gathered_context: gathered_context
    })
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
              %{
                "name" => "update_user",
                "side_effect" => "write",
                "actions" => [%{"name" => "get"}]
              }
            ],
            "require_preview_for_side_effects" => true
          }
        })

      assert {:observe, %{validated: true, next_phase: :preview}} =
               Interactive.next_step(state, %{})
    end

    test "validate denies an action the signature does not list, even on an allowed tool" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "test",
        tool: %ToolCallStep{tool: "lookup_user", action: "delete", args: %{}}
      }

      state = base_state(%{phase: :validate, action_plan: plan})

      assert {:observe, %{denied: true, reason: reason}} = Interactive.next_step(state, %{})
      assert reason =~ ~s(action "delete" of tool "lookup_user")
    end

    test "validate previews a per-action write on a read tool" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "test",
        tool: %ToolCallStep{tool: "lookup_user", action: "update", args: %{}}
      }

      state =
        base_state(%{
          phase: :validate,
          action_plan: plan,
          strategy_config: %{
            "allowed_tool_signatures" => [
              %{
                "name" => "lookup_user",
                "side_effect" => "read",
                "actions" => [%{"name" => "get"}, %{"name" => "update", "side_effect" => "write"}]
              }
            ],
            "require_preview_for_side_effects" => true
          }
        })

      assert {:observe, %{validated: true, next_phase: :preview}} =
               Interactive.next_step(state, %{})
    end

    test "validate skips preview but still gates a plan approved from the journal" do
      allowed = tool_call_plan("update_user")
      denied = tool_call_plan("nuke_everything")

      preview_cfg =
        Map.put(base_state(%{}).strategy_config, "require_preview_for_side_effects", true)

      state =
        base_state(%{
          phase: :validate,
          action_plan: allowed,
          approved_from_journal: true,
          strategy_config: preview_cfg
        })

      assert {:observe, %{validated: true, next_phase: :execute}} =
               Interactive.next_step(state, %{})

      state = %{state | action_plan: denied}
      assert {:observe, %{denied: true}} = Interactive.next_step(state, %{})
    end

    test "validate denies an output type outside allowed_output_types" do
      output = %Cyclium.OutputProposal{type: "sms", dedupe_key: "dk", payload: %{}}
      plan = %ActionPlan{kind: :output_proposal, risk: :low, why: "test", output: output}
      state = base_state(%{phase: :validate, action_plan: plan})

      assert {:observe, %{denied: true, reason: reason}} = Interactive.next_step(state, %{})
      assert reason =~ "allowed_output_types"
    end

    test "validate previews an output proposal that requires approval" do
      output = %Cyclium.OutputProposal{
        type: "email",
        dedupe_key: "dk",
        payload: %{},
        requires_approval: true
      }

      plan = %ActionPlan{kind: :output_proposal, risk: :low, why: "test", output: output}
      state = base_state(%{phase: :validate, action_plan: plan})

      assert {:observe, %{validated: true, next_phase: :preview}} =
               Interactive.next_step(state, %{})
    end

    test "validate denies a workflow trigger outside allowed_workflows" do
      wf = %Cyclium.Intent.WorkflowTrigger{workflow_id: "wf_1", input: %{}}
      plan = %ActionPlan{kind: :workflow_trigger, risk: :low, why: "test", workflow: wf}
      state = base_state(%{phase: :validate, action_plan: plan})

      assert {:observe, %{denied: true, reason: reason}} = Interactive.next_step(state, %{})
      assert reason =~ "allowed_workflows"
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

      # The model's request is nested and tagged so it can never be mistaken
      # for a gated plan the preview phase journaled.
      assert {:approval,
              %{"source" => "request_approval", "request" => %{description: "delete account"}}} =
               Interactive.next_step(state, %{})
    end

    test "preview journals its plan with source: preview" do
      state = base_state(%{phase: :preview, action_plan: tool_call_plan(), plan_hash: "h1"})

      assert {:approval, %{source: "preview", plan_hash: "h1", plan: _}} =
               Interactive.next_step(state, %{})
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

    test "summarize carries the history, and the context sources the actor opted in to" do
      gathered = %{
        message: "hello",
        history: [%{role: "assistant", content: "294 matches."}],
        findings: [%{finding_key: "k", summary: "s"}],
        collected_fields: %{"page_context" => %{"table" => "x"}}
      }

      state =
        summarize_state(gathered)
        |> put_in([:strategy_config, "summarize_context"], ["collected_fields"])

      assert {:synthesize, %{context: context}} = Interactive.next_step(state, %{})
      assert context.collected_fields == gathered.collected_fields
      assert context.history == gathered.history
      refute Map.has_key?(context, :findings)
      refute Map.has_key?(context, :message)
    end

    test "summarize carries only the history by default" do
      state =
        summarize_state(%{
          history: [%{role: "user", content: "q"}],
          collected_fields: %{"a" => 1}
        })

      assert {:synthesize, %{context: context}} = Interactive.next_step(state, %{})
      assert context |> Map.keys() |> Enum.sort() == [:history, :tool_executed, :tool_results]
    end

    test "summarize_context accepts atoms as the DSL writes them, and ignores anything else" do
      config = %{
        summarize_context: [:findings, "collected_fields", "history", %{"x" => 1}, nil, 3]
      }

      assert Loop.summarize_context(config) == [:findings, :collected_fields]
      assert Loop.summarize_context(%{"summarize_context" => "findings"}) == []
      assert Loop.summarize_context(nil) == []
    end

    test "summarize tolerates a missing, non-map or string-keyed gathered context" do
      opted = fn gathered ->
        summarize_state(gathered)
        |> put_in([:strategy_config, "summarize_context"], ["collected_fields"])
      end

      for gathered <- [nil, [collected_fields: %{}], "x"] do
        assert {:synthesize, %{context: context}} = Interactive.next_step(opted.(gathered), %{})
        assert context |> Map.keys() |> Enum.sort() == [:history, :tool_executed, :tool_results]
        assert context.history == []
      end

      assert {:synthesize, %{context: %{collected_fields: %{"a" => 1}}}} =
               Interactive.next_step(opted.(%{"collected_fields" => %{"a" => 1}}), %{})

      assert {:synthesize, %{context: %{collected_fields: false}}} =
               Interactive.next_step(opted.(%{collected_fields: false}), %{})
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

    test "interpret splits a dotted tool name into tool + action" do
      state = base_state(%{phase: :interpret})

      # gpt-5 sometimes merges tool + action into one dotted name, leaving action
      # blank — which otherwise fails the plan gate ("not in allowed signatures").
      raw = %{
        "kind" => "tool_call",
        "risk" => "low",
        "why" => "look up info",
        "tool" => %{"tool" => "lookup_user.get", "action" => "", "args" => %{"id" => 1}}
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.action_plan.kind == :tool_call
      assert new.action_plan.tool.tool == "lookup_user"
      assert new.action_plan.tool.action == "get"
    end

    test "interpret coerces a non-string explanation into a string" do
      state = base_state(%{phase: :interpret})

      # gpt-5.2 sometimes over-structures the answer as a nested object instead of
      # plain prose; it must degrade to text, not leak an inspected blob.
      raw = %{
        "kind" => "explain_only",
        "risk" => "low",
        "why" => "explaining",
        "explanation" => %{"ActionPlan" => %{"can_do" => ["x"], "goal" => "g"}}
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.action_plan.kind == :explain_only
      assert is_binary(new.action_plan.explanation)
      assert new.action_plan.explanation =~ "ActionPlan"
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

    test "summarize with follow-up multi_tool_plan loops back (does not leak the envelope)" do
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{}}]
        })

      # Native mode emits a multi_tool_plan when the model calls several tools at
      # once; the summarize handler must re-execute it, not stringify it into the
      # answer.
      raw = %{
        "kind" => "multi_tool_plan",
        "risk" => "low",
        "why" => "native tool calls",
        "steps" => [
          %{"tool" => "lookup_user", "action" => "get", "args" => %{}},
          %{"tool" => "lookup_user", "action" => "get", "args" => %{}}
        ]
      }

      {:ok, new} = Interactive.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :validate
      assert new.action_plan.kind == :multi_tool_plan
      assert new.explanation in [nil, ""]
    end

    test "summarize error aborts as synthesis_error rather than falling back to done" do
      # Pre-seed the retry counter at the give-up threshold so no backoff sleep runs.
      state =
        base_state(%{
          phase: :summarize,
          action_plan: tool_call_plan(),
          execution_results: [{:ok, %{}}],
          __retries: %{synthesis: 2}
        })

      # An infra failure during summarize must fail the episode, not converge to
      # a misleading no_action / empty done.
      assert {:abort, {:synthesis_error, :api_error, detail}} =
               Interactive.handle_result(
                 state,
                 %{kind: :synthesis},
                 {:error, {:api_error, :timeout}}
               )

      assert detail.completed_tool_steps == 1
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
            %{
              "action" => "raise",
              "finding_key" => "anomaly:1",
              "class" => "anomaly",
              "summary" => "unusual",
              "severity" => "HIGH",
              # identity/lifecycle fields the model may not set
              "actor_id" => "someone_else",
              "env" => "prod",
              "status" => "cleared"
            },
            %{"action" => "clear", "key" => "old_finding", "reason" => "resolved"},
            # no finding_key → dropped
            %{"action" => "raise", "class" => "anomaly", "summary" => "no key"}
          ]
        }
      }

      state = base_state(%{phase: :done, action_plan: plan})

      {:ok, result} = Interactive.converge(state, %{})
      assert length(result.findings) == 2

      assert {:raise, params} = hd(result.findings)
      assert params.finding_key == "anomaly:1"
      assert params.severity == :high
      refute Map.has_key?(params, :actor_id)
      refute Map.has_key?(params, :env)
      refute Map.has_key?(params, :status)
      assert {:clear, "old_finding", "resolved"} = Enum.at(result.findings, 1)
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

  describe "handle_budget_exhausted/2" do
    test "opts into a graceful converge with the budget_exhausted flag set" do
      state = base_state(%{phase: :execute})

      assert {:converge, new_state} = Interactive.handle_budget_exhausted(state, %{})
      assert new_state.budget_exhausted == true
      assert new_state.phase == :done
    end

    test "is safe for states resumed before :budget_exhausted existed" do
      # Older checkpoints have no :budget_exhausted key; Map.put (not %{s | ...})
      # means this must not raise.
      state = base_state(%{phase: :execute}) |> Map.delete(:budget_exhausted)

      assert {:converge, new_state} = Interactive.handle_budget_exhausted(state, %{})
      assert new_state.budget_exhausted == true
    end
  end

  describe "converge/2 with budget exhaustion" do
    test "produces an incomplete classification and a user-facing summary" do
      state = base_state(%{phase: :done, budget_exhausted: true})

      {:ok, result} = Interactive.converge(state, %{})

      assert result.classification == %{"primary" => "incomplete", "reason" => "budget_exhausted"}
      assert result.summary =~ "wasn't able to finish"
    end

    test "reports completed step count when results exist" do
      state =
        base_state(%{
          phase: :done,
          budget_exhausted: true,
          execution_results: [{:ok, %{a: 1}}, {:ok, %{b: 2}}]
        })

      {:ok, result} = Interactive.converge(state, %{})
      assert result.summary =~ "2 step(s)"
    end

    test "includes partial progress when an explanation was produced" do
      state =
        base_state(%{phase: :done, budget_exhausted: true, explanation: "found the resource id"})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.summary =~ "found the resource id"
    end

    test "budget_exhausted takes precedence over a denial reason" do
      state = base_state(%{phase: :done, budget_exhausted: true, deny_reason: "blocked"})

      {:ok, result} = Interactive.converge(state, %{})
      assert result.classification["primary"] == "incomplete"
    end
  end
end

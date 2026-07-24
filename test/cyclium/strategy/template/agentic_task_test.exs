defmodule Cyclium.Strategy.Template.AgenticTaskTest do
  use ExUnit.Case, async: false
  use Cyclium.Test.StrategyCase

  alias Cyclium.Strategy.Template.AgenticTask
  alias Cyclium.Intent.{ActionPlan, ToolCallStep}
  alias Cyclium.ConvergeResult

  # Atom created at compile time so `safe_to_atom/1` resolves the actor_id string
  # back to this atom deterministically for persistent_term lookups.
  @actor_id :agentic_task_test_actor
  @actor_id_str "agentic_task_test_actor"

  # --- Helpers ---

  defp put_config(config) do
    key = {:cyclium_strategy_config, @actor_id, :task}
    :persistent_term.put(key, config)
    on_exit(fn -> :persistent_term.erase(key) end)
  end

  defp base_state(overrides) do
    Map.merge(
      %{
        phase: :context_assembly,
        strategy_config: %{
          "allowed_tool_signatures" => [
            %{"name" => "data", "side_effect" => "read"}
          ]
        },
        message: "the objective",
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
      },
      overrides
    )
  end

  defp finish_result(args) do
    %{
      "kind" => "tool_call",
      "risk" => "low",
      "why" => "task complete",
      "tool" => %{
        "tool" => "finish_agentic_task",
        "action" => "finish_agentic_task",
        "args" => args
      }
    }
  end

  # --- init ---

  describe "init/2" do
    test "interpolates a static objective with event payload values" do
      put_config(%{"objective" => "Review resource {{resource_id}} in {{region}}"})

      episode = build_test_episode(actor_id: @actor_id_str)
      trigger = %Cyclium.Trigger.Event{payload: %{"resource_id" => "R-1", "region" => "us"}}

      {:ok, state} = AgenticTask.init(episode, trigger)
      assert state.message == "Review resource R-1 in us"
      assert state.phase == :context_assembly
    end

    test "a payload objective overrides the static template" do
      put_config(%{"objective" => "static default"})

      episode = build_test_episode(actor_id: @actor_id_str)
      trigger = %Cyclium.Trigger.Event{payload: %{"objective" => "Do {{x}} now", "x" => "it"}}

      {:ok, state} = AgenticTask.init(episode, trigger)
      assert state.message == "Do it now"
    end

    test "unresolved placeholders degrade to empty string" do
      put_config(%{"objective" => "Handle {{missing}} please"})

      episode = build_test_episode(actor_id: @actor_id_str)
      {:ok, state} = AgenticTask.init(episode, %Cyclium.Trigger.Event{payload: %{}})
      assert state.message == "Handle  please"
    end

    test "auto-injects the finish tool and a finish guideline" do
      put_config(%{
        "objective" => "x",
        "allowed_tool_signatures" => [%{"name" => "data", "side_effect" => "read"}],
        "guidelines" => ["Be concise"]
      })

      episode = build_test_episode(actor_id: @actor_id_str)

      {:ok, state} =
        AgenticTask.init(episode, %Cyclium.Trigger.Manual{requested_by: "t", reason: "r"})

      names = Enum.map(state.strategy_config["allowed_tool_signatures"], & &1["name"])
      assert "finish_agentic_task" in names
      assert "data" in names
      assert Enum.any?(state.strategy_config["guidelines"], &(&1 =~ "finish_agentic_task"))
    end

    test "pulls objective from workflow input and manual reason" do
      put_config(%{"objective" => "reason: {{reason}}"})

      episode = build_test_episode(actor_id: @actor_id_str)

      {:ok, wf_state} =
        AgenticTask.init(episode, %Cyclium.Trigger.Workflow{input: %{"reason" => "wf"}})

      assert wf_state.message == "reason: wf"

      {:ok, man_state} =
        AgenticTask.init(episode, %Cyclium.Trigger.Manual{requested_by: "u", reason: "man"})

      assert man_state.message == "reason: man"
    end

    test "interpolates the objective from a manual trigger's payload" do
      put_config(%{"objective" => "Appraise deal {{deal_id}}"})

      episode = build_test_episode(actor_id: @actor_id_str)

      trigger = %Cyclium.Trigger.Manual{
        requested_by: "force_fire",
        reason: "manual",
        payload: %{"deal_id" => "D-42"}
      }

      {:ok, state} = AgenticTask.init(episode, trigger)
      assert state.message == "Appraise deal D-42"
      assert state.payload["deal_id"] == "D-42"
      # requested_by / reason are preserved alongside the payload.
      assert state.payload["requested_by"] == "force_fire"
    end

    test "resolves strategy_config by the exact {actor, expectation} key" do
      # Two configs registered for the same actor under different expectations.
      # The agentic run must get its own, not whichever the actor-scan hits first.
      chat_key = {:cyclium_strategy_config, @actor_id, :chat}
      task_key = {:cyclium_strategy_config, @actor_id, :task}
      :persistent_term.put(chat_key, %{"objective" => "chat objective", "role" => "chat"})
      :persistent_term.put(task_key, %{"objective" => "task objective", "role" => "task"})

      on_exit(fn ->
        :persistent_term.erase(chat_key)
        :persistent_term.erase(task_key)
      end)

      episode = build_test_episode(actor_id: @actor_id_str, expectation_id: "task")

      {:ok, state} =
        AgenticTask.init(episode, %Cyclium.Trigger.Manual{requested_by: "u", reason: "r"})

      assert state.message == "task objective"
      assert state.strategy_config["role"] == "task"
    end
  end

  # --- next_step / handle_result: custom phase + delegation ---

  describe "context_assembly phase" do
    test "next_step emits :observe with objective + payload" do
      state = base_state(%{message: "obj", payload: %{"a" => 1}})
      assert {:observe, ctx} = AgenticTask.next_step(state, %{actor_id: @actor_id_str})
      assert ctx.objective == "obj"
      assert ctx.payload == %{"a" => 1}
    end

    test "handle_result transitions to interpret" do
      state = base_state(%{})
      {:ok, new} = AgenticTask.handle_result(state, %{}, {:ok, %{objective: "obj"}})
      assert new.phase == :interpret
      assert new.gathered_context == %{objective: "obj"}
    end

    test "interpret phase delegates to the shared loop" do
      state = base_state(%{phase: :interpret, gathered_context: %{}})
      assert {:synthesize, prompt} = AgenticTask.next_step(state, %{})
      assert prompt.task == :interpret_intent
    end

    test "execute phase delegates to the shared loop" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "t",
        tool: %ToolCallStep{tool: "data", action: "read", args: %{}}
      }

      state = base_state(%{phase: :execute, action_plan: plan})
      assert {:tool_call, :data, :read, %{}} = AgenticTask.next_step(state, %{})
    end
  end

  # --- finish tool interception ---

  describe "finish tool" do
    test "interpret → finish routes to :done with conclusion" do
      state = base_state(%{phase: :interpret})

      {:ok, new} =
        AgenticTask.handle_result(state, %{}, {:ok, finish_result(%{"summary" => "done early"})})

      assert new.phase == :done
      assert new.conclusion["summary"] == "done early"
    end

    test "summarize → finish routes to :done with conclusion" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "t",
        tool: %ToolCallStep{tool: "data", action: "read", args: %{}}
      }

      state = base_state(%{phase: :summarize, action_plan: plan, execution_results: [{:ok, %{}}]})

      args = %{"summary" => "all gathered", "confidence" => 0.9, "findings" => []}
      {:ok, new} = AgenticTask.handle_result(state, %{}, {:ok, finish_result(args)})

      assert new.phase == :done
      assert new.conclusion["summary"] == "all gathered"
    end

    test "a non-finish tool_call still loops through validate/execute" do
      plan = %ActionPlan{
        kind: :tool_call,
        risk: :low,
        why: "t",
        tool: %ToolCallStep{tool: "data", action: "read", args: %{}}
      }

      state = base_state(%{phase: :summarize, action_plan: plan, execution_results: [{:ok, %{}}]})

      raw = %{
        "kind" => "tool_call",
        "risk" => "low",
        "why" => "more",
        "tool" => %{"tool" => "data", "action" => "read", "args" => %{}}
      }

      {:ok, new} = AgenticTask.handle_result(state, %{}, {:ok, raw})
      assert new.phase == :validate
      assert new.conclusion == nil
    end
  end

  # --- converge ---

  describe "converge/2" do
    test "finish conclusion → task_complete with findings and outputs" do
      conclusion = %{
        "summary" => "Resource is over limit",
        "confidence" => 0.92,
        "findings" => [
          %{"action" => "raise", "class" => "over_limit", "summary" => "R-1 over limit"}
        ],
        "outputs" => [
          %{"type" => "slack", "dedupe_key" => "dk1", "payload" => %{"text" => "alert"}}
        ]
      }

      state = base_state(%{phase: :done, conclusion: conclusion})

      {:ok, %ConvergeResult{} = res} = AgenticTask.converge(state, %{})
      assert res.summary == "Resource is over limit"
      assert res.classification["primary"] == "task_complete"
      assert res.classification["terminal"] == "finish"
      assert res.confidence == 0.92
      assert [{:raise, _}] = res.findings
      assert [%Cyclium.OutputProposal{type: :slack}] = res.outputs
    end

    test "plain explanation (no finish) → task_complete/explanation" do
      state = base_state(%{phase: :done, explanation: "Here is the answer"})

      {:ok, res} = AgenticTask.converge(state, %{})
      assert res.summary == "Here is the answer"
      assert res.classification["terminal"] == "explanation"
      assert res.findings == []
    end

    test "budget exhaustion → incomplete" do
      state = base_state(%{phase: :done, budget_exhausted: true})

      {:ok, res} = AgenticTask.converge(state, %{})
      assert res.classification == %{"primary" => "incomplete", "reason" => "budget_exhausted"}
      assert res.summary =~ "wasn't able to finish"
    end

    test "denied plan → denied classification" do
      state = base_state(%{phase: :done, deny_reason: "tool not allowed"})

      {:ok, res} = AgenticTask.converge(state, %{})
      assert res.classification["primary"] == "denied"
      assert res.summary =~ "blocked"
    end

    test "budget exhaustion takes precedence over a denial" do
      state = base_state(%{phase: :done, budget_exhausted: true, deny_reason: "blocked"})
      {:ok, res} = AgenticTask.converge(state, %{})
      assert res.classification["primary"] == "incomplete"
    end

    test "clamps an out-of-range confidence" do
      state = base_state(%{phase: :done, conclusion: %{"summary" => "s", "confidence" => 5}})
      {:ok, res} = AgenticTask.converge(state, %{})
      assert res.confidence == 1.0
    end
  end

  describe "handle_budget_exhausted/2" do
    test "opts into graceful converge" do
      state = base_state(%{phase: :execute})
      assert {:converge, new} = AgenticTask.handle_budget_exhausted(state, %{})
      assert new.budget_exhausted == true
      assert new.phase == :done
    end
  end

  # --- Full episode loop ---

  describe "full loop termination" do
    test "objective → tool call → finish converges" do
      put_config(%{
        "objective" => "Do {{thing}}",
        "allowed_tool_signatures" => [
          %{
            "name" => "data",
            "side_effect" => "read",
            "actions" => [%{"name" => "read", "args" => %{}}]
          }
        ]
      })

      episode = build_test_episode(actor_id: @actor_id_str)
      trigger = %Cyclium.Trigger.Event{payload: %{"thing" => "the work"}}

      interpret_plan = %{
        "kind" => "tool_call",
        "risk" => "low",
        "why" => "gather",
        "tool" => %{"tool" => "data", "action" => "read", "args" => %{}}
      }

      finish_plan = finish_result(%{"summary" => "completed the work", "confidence" => 0.8})

      handle_step = fn
        {:observe, data}, _s ->
          {:result, {:ok, data}}

        {:synthesize, %{task: :interpret_intent}}, _s ->
          {:result, {:ok, interpret_plan}}

        {:synthesize, %{task: :summarize_results}}, _s ->
          {:result, {:ok, finish_plan}}

        {:tool_call, _c, _a, _args}, _s ->
          {:result, {:ok, %{"used" => 100, "limit" => 80}}}

        other, s ->
          Cyclium.Test.StrategyCase.default_step_handler(other, s)
      end

      assert {:ok, final_state, _steps} =
               assert_strategy_terminates(AgenticTask, episode, trigger,
                 max_steps: 25,
                 handle_step: handle_step
               )

      assert final_state.phase == :done
      assert final_state.conclusion["summary"] == "completed the work"
    end
  end
end

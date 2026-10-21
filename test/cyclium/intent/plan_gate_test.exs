defmodule Cyclium.Intent.PlanGateTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{ActionPlan, PlanGate, ToolCallStep, WorkflowTrigger}

  defp plan(overrides) do
    defaults = %{kind: :explain_only, risk: :low, why: "test"}
    struct!(ActionPlan, Map.merge(defaults, overrides))
  end

  defp step(tool, args \\ %{}, action \\ "go") do
    %ToolCallStep{tool: tool, action: action, args: args}
  end

  defp strategy_cfg(overrides \\ %{}) do
    Map.merge(
      %{
        "allowed_tool_signatures" => [
          %{
            "name" => "lookup_user",
            "side_effect" => "read",
            "constraints" => %{"max_rows" => 50},
            "actions" => [%{"name" => "go"}]
          },
          %{"name" => "update_user", "side_effect" => "write", "actions" => [%{"name" => "go"}]}
        ],
        "allowed_output_types" => ["email"],
        "allowed_workflows" => ["wf_1"]
      },
      overrides
    )
  end

  describe "evaluate/3" do
    test "passes structurally valid explain_only plan" do
      assert :ok = PlanGate.evaluate(plan(%{}), %{}, strategy_cfg())
    end

    test "denies a structurally invalid plan with the gate's {:deny, _} shape" do
      assert {:deny, msg} =
               PlanGate.evaluate(plan(%{kind: :tool_call, tool: nil}), %{}, strategy_cfg())

      assert msg =~ "invalid plan"
    end

    test "passes tool_call matching a signature and a listed action" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user")})
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg())
    end

    test "denies tool_call with no matching signature" do
      p = plan(%{kind: :tool_call, tool: step("delete_everything")})
      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ "not in allowed signatures"
    end

    test "denies an action the signature does not list" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user", %{}, "purge")})
      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ ~s(action "purge" of tool "lookup_user")
    end

    test "a tool whose module still implements an action withheld from this actor is denied" do
      # A host may publish a tool's signature with one action left out
      # (`tool_signature(except: [:withheld])`) while the module keeps its
      # `call(:withheld, ...)` clause for another actor. The gate must not let
      # the model reach it through the tool name alone.
      cfg = %{
        "allowed_tool_signatures" => [
          %{"name" => "query", "side_effect" => "read", "actions" => [%{"name" => "list"}]}
        ]
      }

      assert :ok =
               PlanGate.evaluate(
                 plan(%{kind: :tool_call, tool: step("query", %{}, "list")}),
                 %{},
                 cfg
               )

      assert {:deny, _} =
               PlanGate.evaluate(
                 plan(%{kind: :tool_call, tool: step("query", %{}, "withheld")}),
                 %{},
                 cfg
               )
    end

    test "denies when constraint exceeded" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user", %{"limit" => 100})})
      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ "max_rows"
    end

    test "passes multi_tool_plan when all tools and actions match" do
      p =
        plan(%{
          kind: :multi_tool_plan,
          steps: [step("lookup_user"), step("update_user")]
        })

      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg())
    end

    test "denies multi_tool_plan when one tool doesn't match" do
      p =
        plan(%{
          kind: :multi_tool_plan,
          steps: [step("lookup_user"), step("nuke_db")]
        })

      assert {:deny, _} = PlanGate.evaluate(p, %{}, strategy_cfg())
    end

    test "denies multi_tool_plan when one step's action is not listed" do
      p =
        plan(%{
          kind: :multi_tool_plan,
          steps: [step("lookup_user"), step("update_user", %{}, "drop")]
        })

      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ ~s(action "drop")
    end

    test "enforces max_plan_steps from config" do
      steps = for _i <- 1..5, do: step("lookup_user")

      p = plan(%{kind: :multi_tool_plan, steps: steps})

      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg(%{"max_plan_steps" => 3}))
      assert msg =~ "max_plan_steps"
    end

    test "passes with no signatures configured" do
      p = plan(%{})
      assert :ok = PlanGate.evaluate(p, %{}, %{})
    end

    test "output proposal passes only for a type in allowed_output_types" do
      allowed = %Cyclium.OutputProposal{type: "email", dedupe_key: "dk", payload: %{}}
      other = %Cyclium.OutputProposal{type: :sms, dedupe_key: "dk", payload: %{}}

      assert :ok =
               PlanGate.evaluate(
                 plan(%{kind: :output_proposal, output: allowed}),
                 %{},
                 strategy_cfg()
               )

      assert {:deny, msg} =
               PlanGate.evaluate(
                 plan(%{kind: :output_proposal, output: other}),
                 %{},
                 strategy_cfg()
               )

      assert msg =~ "allowed_output_types"
    end

    test "output proposal is denied when no allowed_output_types are configured" do
      output = %Cyclium.OutputProposal{type: "email", dedupe_key: "dk", payload: %{}}

      assert {:deny, _} =
               PlanGate.evaluate(
                 plan(%{kind: :output_proposal, output: output}),
                 %{},
                 strategy_cfg(%{"allowed_output_types" => []})
               )
    end

    test "workflow_trigger passes only for a workflow in allowed_workflows" do
      assert :ok =
               PlanGate.evaluate(
                 plan(%{
                   kind: :workflow_trigger,
                   workflow: %WorkflowTrigger{workflow_id: "wf_1"}
                 }),
                 %{},
                 strategy_cfg()
               )

      assert {:deny, msg} =
               PlanGate.evaluate(
                 plan(%{
                   kind: :workflow_trigger,
                   workflow: %WorkflowTrigger{workflow_id: "wf_2"}
                 }),
                 %{},
                 strategy_cfg()
               )

      assert msg =~ "allowed_workflows"
    end

    test "workflow_trigger is denied when no allowed_workflows are configured" do
      assert {:deny, _} =
               PlanGate.evaluate(
                 plan(%{
                   kind: :workflow_trigger,
                   workflow: %WorkflowTrigger{workflow_id: "wf_1"}
                 }),
                 %{},
                 strategy_cfg(%{"allowed_workflows" => []})
               )
    end
  end
end

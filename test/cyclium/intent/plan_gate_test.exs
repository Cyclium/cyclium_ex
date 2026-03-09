defmodule Cyclium.Intent.PlanGateTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{ActionPlan, PlanGate, ToolCallStep, WorkflowTrigger}

  defp plan(overrides) do
    defaults = %{kind: :explain_only, risk: :low, why: "test"}
    struct!(ActionPlan, Map.merge(defaults, overrides))
  end

  defp step(tool, args \\ %{}) do
    %ToolCallStep{tool: tool, action: "go", args: args}
  end

  defp strategy_cfg(overrides \\ %{}) do
    Map.merge(
      %{
        "allowed_tool_signatures" => [
          %{
            "name" => "lookup_user",
            "side_effect" => "read",
            "constraints" => %{"max_rows" => 50}
          },
          %{"name" => "update_user", "side_effect" => "write"}
        ]
      },
      overrides
    )
  end

  describe "evaluate/3" do
    test "passes structurally valid explain_only plan" do
      assert :ok = PlanGate.evaluate(plan(%{}), %{}, strategy_cfg())
    end

    test "rejects structurally invalid plan" do
      assert {:error, _} =
               PlanGate.evaluate(plan(%{kind: :tool_call, tool: nil}), %{}, strategy_cfg())
    end

    test "passes tool_call matching a signature" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user")})
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg())
    end

    test "denies tool_call with no matching signature" do
      p = plan(%{kind: :tool_call, tool: step("delete_everything")})
      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ "not in allowed signatures"
    end

    test "denies when constraint exceeded" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user", %{"limit" => 100})})
      assert {:deny, msg} = PlanGate.evaluate(p, %{}, strategy_cfg())
      assert msg =~ "max_rows"
    end

    test "passes multi_tool_plan when all tools match" do
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

    test "enforces max_plan_steps from config" do
      steps = for _i <- 1..5, do: step("lookup_user")

      p = plan(%{kind: :multi_tool_plan, steps: steps})

      assert {:error, _} = PlanGate.evaluate(p, %{}, strategy_cfg(%{"max_plan_steps" => 3}))
    end

    test "passes with no signatures configured" do
      p = plan(%{})
      assert :ok = PlanGate.evaluate(p, %{}, %{})
    end

    test "workflow_trigger passes structural validation" do
      wf = %WorkflowTrigger{workflow_id: "wf_1"}
      p = plan(%{kind: :workflow_trigger, workflow: wf})
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg())
    end
  end
end

defmodule Cyclium.Intent.PlanValidatorTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{ActionPlan, PlanValidator, ToolCallStep, WorkflowTrigger}

  defp plan(overrides) do
    defaults = %{kind: :explain_only, risk: :low, why: "test"}
    struct!(ActionPlan, Map.merge(defaults, overrides))
  end

  describe "validate/2 structural" do
    test "passes for valid explain_only" do
      assert :ok = PlanValidator.validate(plan(%{}))
    end

    test "rejects unknown kind" do
      assert {:error, "unknown plan kind: :bogus"} =
               PlanValidator.validate(plan(%{kind: :bogus}))
    end

    test "rejects unknown risk level" do
      assert {:error, "unknown risk level: :critical"} =
               PlanValidator.validate(plan(%{risk: :critical}))
    end
  end

  describe "validate/2 kind-specific fields" do
    test "tool_call requires tool" do
      assert {:error, ":tool_call requires tool field"} =
               PlanValidator.validate(plan(%{kind: :tool_call, tool: nil}))
    end

    test "tool_call passes with tool" do
      step = %ToolCallStep{tool: "lookup_user", action: "get", args: %{}}

      assert :ok = PlanValidator.validate(plan(%{kind: :tool_call, tool: step}))
    end

    test "multi_tool_plan requires at least 1 step" do
      assert {:error, ":multi_tool_plan requires at least 1 step"} =
               PlanValidator.validate(plan(%{kind: :multi_tool_plan, steps: []}))
    end

    test "multi_tool_plan enforces max_plan_steps" do
      steps =
        for i <- 1..3 do
          %ToolCallStep{tool: "t#{i}", action: "go", args: %{}}
        end

      assert {:error, ":multi_tool_plan exceeds max_plan_steps (2)"} =
               PlanValidator.validate(plan(%{kind: :multi_tool_plan, steps: steps}),
                 max_plan_steps: 2
               )
    end

    test "multi_tool_plan passes within limit" do
      steps = [%ToolCallStep{tool: "t1", action: "go", args: %{}}]

      assert :ok = PlanValidator.validate(plan(%{kind: :multi_tool_plan, steps: steps}))
    end

    test "output_proposal requires output" do
      assert {:error, ":output_proposal requires output field"} =
               PlanValidator.validate(plan(%{kind: :output_proposal, output: nil}))
    end

    test "request_approval requires approval" do
      assert {:error, ":request_approval requires approval field"} =
               PlanValidator.validate(plan(%{kind: :request_approval, approval: nil}))
    end

    test "request_approval passes with approval" do
      assert :ok =
               PlanValidator.validate(
                 plan(%{kind: :request_approval, approval: %{description: "delete it"}})
               )
    end

    test "workflow_trigger requires workflow" do
      assert {:error, ":workflow_trigger requires workflow field"} =
               PlanValidator.validate(plan(%{kind: :workflow_trigger, workflow: nil}))
    end

    test "workflow_trigger requires workflow_id" do
      wf = %WorkflowTrigger{workflow_id: nil}

      assert {:error, ":workflow_trigger requires workflow_id"} =
               PlanValidator.validate(plan(%{kind: :workflow_trigger, workflow: wf}))
    end

    test "workflow_trigger passes with valid workflow" do
      wf = %WorkflowTrigger{workflow_id: "wf_1"}

      assert :ok = PlanValidator.validate(plan(%{kind: :workflow_trigger, workflow: wf}))
    end
  end
end

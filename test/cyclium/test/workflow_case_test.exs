defmodule Cyclium.Test.WorkflowCaseTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.WorkflowCase

  alias Cyclium.TestKit.SampleWorkflow

  describe "assert_valid_workflow/1" do
    test "passes for a valid workflow" do
      assert :ok = assert_valid_workflow(SampleWorkflow)
    end

    test "validates existing test workflows" do
      assert :ok = assert_valid_workflow(TestWorkflows.TwoStep)
      assert :ok = assert_valid_workflow(TestWorkflows.Parallel)
      assert :ok = assert_valid_workflow(TestWorkflows.Debounced)
    end
  end

  describe "assert_failure_policies_valid/1" do
    test "passes for valid policies" do
      assert_failure_policies_valid(SampleWorkflow)
    end

    test "passes for test workflows" do
      assert_failure_policies_valid(TestWorkflows.TwoStep)
    end
  end

  describe "assert_failure_policies_complete/1" do
    test "passes when all steps have policies" do
      assert_failure_policies_complete(SampleWorkflow)
      assert_failure_policies_complete(TestWorkflows.TwoStep)
    end

    test "fails when steps are missing policies" do
      assert_raise ArgumentError, ~r/no failure policy/, fn ->
        assert_failure_policies_complete(TestWorkflows.Parallel)
      end
    end
  end

  describe "assert_step_inputs_safe/2" do
    test "passes for valid trigger payload" do
      assert_step_inputs_safe(SampleWorkflow, trigger: %{"entity_id" => "e-123"})
    end

    test "passes for test workflows" do
      assert_step_inputs_safe(TestWorkflows.TwoStep,
        trigger: %{"order_id" => "ord-1"}
      )
    end

    test "passes with custom prior results" do
      assert_step_inputs_safe(SampleWorkflow,
        trigger: %{"entity_id" => "e-456"},
        prior: %{gather: %{"result" => "data"}, analyze: %{"done" => true}}
      )
    end

    test "passes for parallel workflow" do
      assert_step_inputs_safe(TestWorkflows.Parallel,
        trigger: %{"batch_id" => "b-1"}
      )
    end
  end
end

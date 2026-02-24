defmodule Cyclium.WorkflowDSLTest do
  use ExUnit.Case, async: true

  # Test workflow modules are defined in test/support/test_workflows.ex

  describe "use Cyclium.Workflow" do
    test "generates __workflow_config__/0 with correct structure" do
      config = TestWorkflows.TwoStep.__workflow_config__()

      assert %Cyclium.Workflow.Config{} = config
      assert config.workflow_id == "Elixir.TestWorkflows.TwoStep"
      assert config.trigger == {:event, "order.created"}
      assert map_size(config.steps) == 2
      assert Map.has_key?(config.steps, :validate)
      assert Map.has_key?(config.steps, :fulfill)
    end

    test "step config has correct fields" do
      config = TestWorkflows.TwoStep.__workflow_config__()

      validate = config.steps.validate
      assert validate.id == :validate
      assert validate.actor == TestWorkflows.FakeActor
      assert validate.expectation == :validate_order
      assert validate.depends_on == []

      fulfill = config.steps.fulfill
      assert fulfill.id == :fulfill
      assert fulfill.depends_on == [:validate]
    end

    test "failure policies are parsed" do
      config = TestWorkflows.TwoStep.__workflow_config__()

      assert config.failure_policies.validate == %{policy: :abort}
      assert config.failure_policies.fulfill.policy == :retry
      assert config.failure_policies.fulfill.max_step_attempts == 2
      assert config.failure_policies.fulfill.backoff_ms == 100
    end

    test "input function works via __workflow_step_input__/3" do
      trigger = %{"order_id" => "ORD-123"}
      result = TestWorkflows.TwoStep.__workflow_step_input__(:validate, trigger, %{})
      assert result == %{order_id: "ORD-123"}
    end

    test "input function receives prior results" do
      result =
        TestWorkflows.TwoStep.__workflow_step_input__(:fulfill, %{}, %{validate: %{ok: true}})

      assert result == %{validated: %{ok: true}}
    end

    test "parallel steps workflow compiles correctly" do
      config = TestWorkflows.Parallel.__workflow_config__()

      assert map_size(config.steps) == 3
      assert config.steps.step_a.depends_on == []
      assert config.steps.step_b.depends_on == []
      assert config.steps.step_c.depends_on == [:step_a, :step_b]
    end
  end
end

defmodule TestWorkflows.FakeActor do
  @moduledoc false
end

defmodule TestWorkflows.TwoStep do
  use Cyclium.Workflow

  workflow do
    trigger {:event, "order.created"}

    step :validate,
      actor: TestWorkflows.FakeActor,
      expectation: :validate_order,
      input: fn trigger, _prior -> %{order_id: trigger["order_id"]} end

    step :fulfill,
      actor: TestWorkflows.FakeActor,
      expectation: :fulfill_order,
      depends_on: [:validate],
      input: fn _trigger, prior -> %{validated: prior[:validate]} end

    on_failure :validate, :abort
    on_failure :fulfill, :retry, max_step_attempts: 2, backoff_ms: 100
  end
end

defmodule TestWorkflows.Parallel do
  use Cyclium.Workflow

  workflow do
    trigger {:event, "batch.started"}

    step :step_a,
      actor: TestWorkflows.FakeActor,
      expectation: :task_a,
      input: fn _trigger, _prior -> %{} end

    step :step_b,
      actor: TestWorkflows.FakeActor,
      expectation: :task_b,
      input: fn _trigger, _prior -> %{} end

    step :step_c,
      actor: TestWorkflows.FakeActor,
      expectation: :task_c,
      depends_on: [:step_a, :step_b],
      input: fn _trigger, prior -> %{a: prior[:step_a], b: prior[:step_b]} end
  end
end

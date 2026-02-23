defmodule Cyclium.WorkflowEngineTest do
  use ExUnit.Case, async: false

  alias Cyclium.WorkflowEngine
  alias Cyclium.WorkflowInstances

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    {:ok, _} = Cyclium.FakeRunner.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    start_supervised!({Phoenix.PubSub, name: Cyclium.TestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TestPubSub)

    {:ok, engine} =
      start_supervised(
        {WorkflowEngine, name: :"engine_#{System.unique_integer([:positive])}", workflows: [TestWorkflows.TwoStep]}
      )

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
    end)

    %{engine: engine}
  end

  describe "start_workflow/3" do
    test "creates instance and starts ready steps", %{engine: engine} do
      trigger = %{"order_id" => "ORD-100"}

      assert {:ok, instance_id} =
               WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, trigger)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.status == :running
      assert instance.workflow_id == "Elixir.TestWorkflows.TwoStep"

      # The validate step should have started (no deps)
      assert instance.step_states["validate"]["status"] == "running"
      # The fulfill step should still be pending (depends on validate)
      assert instance.step_states["fulfill"]["status"] == "pending"

      # FakeRunner should have been called
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 1
    end
  end

  describe "step completion" do
    test "completing a step advances the workflow", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-200"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      # Simulate episode completion by broadcasting on Bus
      Cyclium.Bus.broadcast("episode.completed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :done,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      # Give GenServer time to process
      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.step_states["validate"]["status"] == "done"
      # fulfill should now be running
      assert instance.step_states["fulfill"]["status"] == "running"
    end

    test "all steps done completes the workflow", %{engine: engine} do
      ref = make_ref()

      :telemetry.attach(
        "test-wf-complete-#{inspect(ref)}",
        [:cyclium, :workflow, :completed],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-300"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      # Complete validate step
      Cyclium.Bus.broadcast("episode.completed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :done,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      fulfill_episode_id = instance.step_states["fulfill"]["episode_id"]

      # Complete fulfill step
      Cyclium.Bus.broadcast("episode.completed", %{
        episode_id: fulfill_episode_id,
        actor_id: "fake_actor",
        status: :done,
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.status == :done

      assert_receive {:telemetry, [:cyclium, :workflow, :completed], %{count: 1}, meta}
      assert meta.instance_id == instance_id

      :telemetry.detach("test-wf-complete-#{inspect(ref)}")
    end
  end

  describe "failure policies" do
    test "abort policy fails the workflow", %{engine: engine} do
      ref = make_ref()

      :telemetry.attach(
        "test-wf-failed-#{inspect(ref)}",
        [:cyclium, :workflow, :failed],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-400"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      # Fail the validate step (has :abort policy)
      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.status == :failed

      assert_receive {:telemetry, [:cyclium, :workflow, :failed], %{count: 1}, _meta}

      :telemetry.detach("test-wf-failed-#{inspect(ref)}")
    end

    test "retry policy creates new episode", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-500"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      # Complete validate
      Cyclium.Bus.broadcast("episode.completed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :done,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      fulfill_episode_id = instance.step_states["fulfill"]["episode_id"]
      initial_enqueue_count = length(Cyclium.FakeRunner.enqueued_episodes())

      # Fail the fulfill step (has :retry policy with backoff_ms: 100)
      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: fulfill_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      Process.sleep(50)

      # Step should be in retrying state
      instance = WorkflowInstances.get!(instance_id)
      assert instance.step_states["fulfill"]["status"] == "retrying"
      assert instance.step_states["fulfill"]["attempts"] == 2
      assert instance.status == :running

      # Wait for backoff to trigger retry
      Process.sleep(150)

      # New episode should be enqueued
      assert length(Cyclium.FakeRunner.enqueued_episodes()) > initial_enqueue_count
    end

    test "retry exhaustion escalates to abort", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-600"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      # Complete validate
      Cyclium.Bus.broadcast("episode.completed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :done,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      Process.sleep(50)

      # Fail fulfill twice (max_step_attempts: 2)
      instance = WorkflowInstances.get!(instance_id)
      fulfill_episode_id = instance.step_states["fulfill"]["episode_id"]

      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: fulfill_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      # Wait for backoff + retry
      Process.sleep(200)

      instance = WorkflowInstances.get!(instance_id)
      new_fulfill_id = instance.step_states["fulfill"]["episode_id"]

      # Fail the retry episode
      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: new_fulfill_id,
        actor_id: "fake_actor",
        status: :failed,
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.status == :failed
    end
  end

  describe "parallel steps" do
    test "independent steps start simultaneously" do
      {:ok, parallel_engine} =
        WorkflowEngine.start_link(
          name: :"engine_parallel_#{System.unique_integer([:positive])}",
          workflows: [TestWorkflows.Parallel]
        )

      Cyclium.FakeRunner.reset()

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(parallel_engine, TestWorkflows.Parallel, %{})

      # Allow GenServer to fully process
      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)

      # step_a and step_b should both be running (no deps)
      assert instance.step_states["step_a"]["status"] == "running"
      assert instance.step_states["step_b"]["status"] == "running"
      # step_c should be pending (depends on both)
      assert instance.step_states["step_c"]["status"] == "pending"

      # Two episodes should be enqueued
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 2

      GenServer.stop(parallel_engine)
    end
  end

  describe "telemetry" do
    test "emits workflow started telemetry", %{engine: engine} do
      ref = make_ref()

      :telemetry.attach(
        "test-wf-started-#{inspect(ref)}",
        [:cyclium, :workflow, :started],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-700"})

      assert_receive {:telemetry, [:cyclium, :workflow, :started], %{count: 1}, meta}
      assert meta.workflow_id == "Elixir.TestWorkflows.TwoStep"

      :telemetry.detach("test-wf-started-#{inspect(ref)}")
    end

    test "emits step started telemetry", %{engine: engine} do
      ref = make_ref()

      :telemetry.attach(
        "test-wf-step-started-#{inspect(ref)}",
        [:cyclium, :workflow, :step_started],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-800"})

      assert_receive {:telemetry, [:cyclium, :workflow, :step_started], %{count: 1}, meta}
      assert meta.step_id == :validate

      :telemetry.detach("test-wf-step-started-#{inspect(ref)}")
    end
  end
end

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
        {WorkflowEngine,
         name: :"engine_#{System.unique_integer([:positive])}", workflows: [TestWorkflows.TwoStep]}
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

    test "abort marks the triggering step as failed in step_states", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-401"})

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: validate_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        workflow_instance_id: instance_id,
        workflow_step_id: "validate"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.step_states["validate"]["status"] == "failed"
      assert instance.step_states["fulfill"]["status"] == "canceled"
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

    test "retry skipped when error_class is in skip_on_error_class list" do
      {:ok, skip_engine} =
        start_supervised(
          {WorkflowEngine,
           name: :"engine_skip_#{System.unique_integer([:positive])}",
           workflows: [TestWorkflows.SkipRetryOnBudget]},
          id: :"skip_engine_#{System.unique_integer([:positive])}"
        )

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(
          skip_engine,
          TestWorkflows.SkipRetryOnBudget,
          %{"order_id" => "ORD-SKIP"}
        )

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

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

      # Fail with budget_exceeded — should NOT retry even though max_step_attempts=3
      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: fulfill_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        error_class: "budget_exceeded",
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      # Should go straight to failed — no retry
      assert instance.step_states["fulfill"]["status"] == "failed"
      assert instance.status == :failed
    end

    test "retry still happens for error_class not in skip list" do
      {:ok, skip_engine} =
        start_supervised(
          {WorkflowEngine,
           name: :"engine_skip_#{System.unique_integer([:positive])}",
           workflows: [TestWorkflows.SkipRetryOnBudget]},
          id: :"skip_engine2_#{System.unique_integer([:positive])}"
        )

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(
          skip_engine,
          TestWorkflows.SkipRetryOnBudget,
          %{"order_id" => "ORD-RETRY"}
        )

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

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

      # Fail with a non-skipped error class — should retry normally
      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: fulfill_episode_id,
        actor_id: "fake_actor",
        status: :failed,
        error_class: "transport_error",
        workflow_instance_id: instance_id,
        workflow_step_id: "fulfill"
      })

      Process.sleep(50)

      instance = WorkflowInstances.get!(instance_id)
      assert instance.step_states["fulfill"]["status"] == "retrying"
      assert instance.status == :running
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

  describe "dry run mode" do
    test "instance stores mode and dry_run_opts", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR1"},
          mode: :dry_run,
          dry_run_opts: %{persist_findings: true}
        )

      instance = WorkflowInstances.get!(instance_id)
      assert instance.mode == "dry_run"
      assert instance.dry_run_opts == %{"persist_findings" => true}
    end

    test "step episodes inherit mode from instance", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR2"},
          mode: :dry_run,
          dry_run_opts: %{persist_findings: "experiment1"}
        )

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      episode = Cyclium.Episodes.get!(validate_episode_id)
      assert episode.mode == "dry_run"
      assert episode.dry_run_opts == %{"persist_findings" => "experiment1"}
    end

    test "subsequent steps inherit mode after completion", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR3"},
          mode: :dry_run
        )

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

      fulfill_episode = Cyclium.Episodes.get!(fulfill_episode_id)
      assert fulfill_episode.mode == "dry_run"
    end

    test "default mode is live", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR4"})

      instance = WorkflowInstances.get!(instance_id)
      assert instance.mode == "live"
      assert instance.dry_run_opts == nil
    end

    test "per-step overrides merge into episode dry_run_opts", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR6"},
          mode: :dry_run,
          dry_run_opts: %{
            persist_findings: true,
            steps: %{
              "validate" => %{
                "synthesis_override" => %{"class" => "approved"}
              },
              "fulfill" => %{
                "tool_overrides" => %{"erp.create_order" => %{"id" => "mock-123"}},
                "persist_findings" => "experiment1"
              }
            }
          }
        )

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      validate_episode = Cyclium.Episodes.get!(validate_episode_id)
      # Global persist_findings + step-specific synthesis_override, no "steps" key
      assert validate_episode.dry_run_opts["persist_findings"] == true
      assert validate_episode.dry_run_opts["synthesis_override"] == %{"class" => "approved"}
      refute Map.has_key?(validate_episode.dry_run_opts, "steps")
    end

    test "per-step override overrides global key", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR7"},
          mode: :dry_run,
          dry_run_opts: %{
            persist_findings: true,
            steps: %{
              "validate" => %{"persist_findings" => "validate_only"}
            }
          }
        )

      instance = WorkflowInstances.get!(instance_id)
      validate_episode_id = instance.step_states["validate"]["episode_id"]

      validate_episode = Cyclium.Episodes.get!(validate_episode_id)
      # Step-level persist_findings overrides global
      assert validate_episode.dry_run_opts["persist_findings"] == "validate_only"
    end

    test "dry run with custom string prefix in opts", %{engine: engine} do
      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.TwoStep, %{"order_id" => "ORD-DR5"},
          mode: :dry_run,
          dry_run_opts: [persist_findings: "batch_test"]
        )

      instance = WorkflowInstances.get!(instance_id)
      assert instance.dry_run_opts == %{"persist_findings" => "batch_test"}
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

  describe "workflow debounce" do
    test "debounce delays workflow start" do
      {:ok, engine} =
        WorkflowEngine.start_link(
          name: :"engine_debounce_#{System.unique_integer([:positive])}",
          workflows: [TestWorkflows.Debounced]
        )

      Cyclium.FakeRunner.reset()

      # Fire event
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-1"})
      Process.sleep(50)

      # Should NOT have started yet (200ms debounce)
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 0

      # Wait for debounce to fire
      Process.sleep(250)

      # Now it should have started
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 1

      GenServer.stop(engine)
    end

    test "rapid events coalesce into single workflow" do
      {:ok, engine} =
        WorkflowEngine.start_link(
          name: :"engine_coalesce_#{System.unique_integer([:positive])}",
          workflows: [TestWorkflows.Debounced]
        )

      Cyclium.FakeRunner.reset()

      # Fire 3 rapid events for the same subject
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-2"})
      Process.sleep(50)
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-2"})
      Process.sleep(50)
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-2"})

      # Wait for debounce (200ms from last event)
      Process.sleep(300)

      # Only one workflow should have started
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 1

      GenServer.stop(engine)
    end

    test "different subjects debounce independently" do
      {:ok, engine} =
        WorkflowEngine.start_link(
          name: :"engine_subjects_#{System.unique_integer([:positive])}",
          workflows: [TestWorkflows.Debounced]
        )

      Cyclium.FakeRunner.reset()

      # Fire events for two different subjects
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-A"})
      Cyclium.Bus.broadcast("entity.updated", %{entity_id: "E-B"})

      # Wait for debounce
      Process.sleep(300)

      # Two workflows should have started (one per subject)
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 2

      GenServer.stop(engine)
    end

    test "no debounce fires immediately", %{engine: _engine} do
      # Use the setup engine (TwoStep has no debounce)
      Cyclium.FakeRunner.reset()
      before_count = length(Cyclium.FakeRunner.enqueued_episodes())

      Cyclium.Bus.broadcast("order.created", %{"order_id" => "ORD-NODEBNC"})
      Process.sleep(50)

      # Should have fired immediately (at least 1 new episode)
      after_count = length(Cyclium.FakeRunner.enqueued_episodes())
      assert after_count > before_count
    end

    test "debounce without subject_key uses workflow_id as key" do
      {:ok, engine} =
        WorkflowEngine.start_link(
          name: :"engine_nosub_#{System.unique_integer([:positive])}",
          workflows: [TestWorkflows.DebouncedNoSubject]
        )

      Cyclium.FakeRunner.reset()

      # Fire 3 rapid events (no subject_key, all coalesce)
      Cyclium.Bus.broadcast("global.updated", %{data: "a"})
      Process.sleep(50)
      Cyclium.Bus.broadcast("global.updated", %{data: "b"})
      Process.sleep(50)
      Cyclium.Bus.broadcast("global.updated", %{data: "c"})

      Process.sleep(300)

      # Only one workflow
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 1

      GenServer.stop(engine)
    end
  end
end

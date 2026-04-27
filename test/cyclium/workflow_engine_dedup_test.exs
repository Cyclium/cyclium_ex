defmodule Cyclium.WorkflowEngineDedupTest do
  @moduledoc """
  Integration tests for cross-node workflow-instance deduplication via
  `Cyclium.WorkClaims`.

  Each "node" is simulated by a separate `WorkflowEngine` GenServer process
  (different `:name`). Both engines see the same DB and contend on the
  same `cyclium_work_claims` row keyed on `(stack, workflow_id, subject_value)`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyclium.Schemas.WorkflowInstance
  alias Cyclium.Test.Repo
  alias Cyclium.WorkflowEngine
  alias Cyclium.WorkflowInstances

  setup do
    # Take direct ownership of a sandbox connection from the test process and
    # switch to shared mode so engine GenServers and Task children can use it.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:cyclium, :repo, Repo)

    start_supervised!({Phoenix.PubSub, name: Cyclium.DedupTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.DedupTestPubSub)

    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    Application.put_env(:cyclium, :node_identity, "node@dedup_test")

    prior_claims = Application.get_env(:cyclium, :work_claims)
    Application.put_env(:cyclium, :work_claims, Cyclium.WorkClaims.EctoClaims)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
      Application.delete_env(:cyclium, :node_identity)
      Application.delete_env(:cyclium, :stack_slug)
      Application.delete_env(:cyclium, :repo)

      if prior_claims,
        do: Application.put_env(:cyclium, :work_claims, prior_claims),
        else: Application.delete_env(:cyclium, :work_claims)
    end)

    :ok
  end

  defp start_engine(name, workflows) do
    start_supervised!(
      Supervisor.child_spec({WorkflowEngine, name: name, workflows: workflows}, id: name)
    )

    name
  end

  defp count_instances(workflow_id) do
    from(wi in WorkflowInstance,
      where: wi.workflow_id == ^workflow_id,
      select: count(wi.id)
    )
    |> Repo.one()
  end

  defp attach_telemetry(event) do
    handler_id = "dedup-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      &Cyclium.TelemetryHelper.handle_event/4,
      %{test_pid: test_pid}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "subject_value stamping" do
    test "stamps from configured subject_key" do
      engine = start_engine(:dedup_subj_a, [TestWorkflows.Debounced])

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{
          "entity_id" => "E-1"
        })

      assert WorkflowInstances.get!(instance_id).subject_value == "E-1"
    end

    test "defaults to underscore when no subject_key configured" do
      engine = start_engine(:dedup_subj_b, [TestWorkflows.DebouncedNoSubject])

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.DebouncedNoSubject, %{})

      assert WorkflowInstances.get!(instance_id).subject_value == "_"
    end

    test "defaults to underscore when subject_key set but payload missing the key" do
      engine = start_engine(:dedup_subj_c, [TestWorkflows.Debounced])

      {:ok, instance_id} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{})

      assert WorkflowInstances.get!(instance_id).subject_value == "_"
    end
  end

  describe "concurrent engines (cross-node race)" do
    test "two engines racing on the same workflow + subject yield exactly one instance" do
      engine_a = start_engine(:race_engine_a, [TestWorkflows.Debounced])
      engine_b = start_engine(:race_engine_b, [TestWorkflows.Debounced])

      attach_telemetry([:cyclium, :workflow, :duplicate_blocked])

      payload = %{"entity_id" => "RACE-1"}

      tasks = [
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_a, TestWorkflows.Debounced, payload)
        end),
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_b, TestWorkflows.Debounced, payload)
        end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      successes = Enum.count(results, &match?({:ok, _}, &1))
      duplicates = Enum.count(results, &match?({:error, :duplicate_in_flight}, &1))

      assert successes == 1, "expected exactly one successful create, got #{inspect(results)}"

      assert duplicates == 1,
             "expected exactly one duplicate_in_flight rejection, got #{inspect(results)}"

      assert count_instances("Elixir.TestWorkflows.Debounced") == 1

      assert_receive {:telemetry, [:cyclium, :workflow, :duplicate_blocked], %{count: 1},
                      %{workflow_id: "Elixir.TestWorkflows.Debounced", subject_value: "RACE-1"}},
                     1_000
    end

    test "different subjects do not collide" do
      engine_a = start_engine(:diff_subj_engine_a, [TestWorkflows.Debounced])
      engine_b = start_engine(:diff_subj_engine_b, [TestWorkflows.Debounced])

      tasks = [
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_a, TestWorkflows.Debounced, %{"entity_id" => "A"})
        end),
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_b, TestWorkflows.Debounced, %{"entity_id" => "B"})
        end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert count_instances("Elixir.TestWorkflows.Debounced") == 2
    end
  end

  describe "stack isolation" do
    test "different stacks with same workflow + subject both create their own instance" do
      engine = start_engine(:stack_iso_engine, [TestWorkflows.Debounced])

      Application.put_env(:cyclium, :stack_slug, "stack_a")

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{"entity_id" => "X"})

      Application.put_env(:cyclium, :stack_slug, "stack_b")

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{"entity_id" => "X"})

      assert count_instances("Elixir.TestWorkflows.Debounced") == 2

      instances =
        from(wi in WorkflowInstance, where: wi.workflow_id == "Elixir.TestWorkflows.Debounced")
        |> Repo.all()

      stacks = instances |> Enum.map(& &1.source_stack) |> Enum.sort()
      assert stacks == ["stack_a", "stack_b"]
    end
  end

  describe "claim release after create" do
    test "second sequential call for the same subject succeeds (claim was released)" do
      engine = start_engine(:release_engine, [TestWorkflows.Debounced])

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{"entity_id" => "REL"})

      {:ok, _} =
        WorkflowEngine.start_workflow(engine, TestWorkflows.Debounced, %{"entity_id" => "REL"})

      assert count_instances("Elixir.TestWorkflows.Debounced") == 2
    end
  end

  describe "passthrough mode (work_claims unconfigured)" do
    @tag :work_claims_off
    test "without work_claims, two engines both create — documents the dependency" do
      Application.delete_env(:cyclium, :work_claims)

      engine_a = start_engine(:passthrough_engine_a, [TestWorkflows.Debounced])
      engine_b = start_engine(:passthrough_engine_b, [TestWorkflows.Debounced])

      payload = %{"entity_id" => "PT-1"}

      tasks = [
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_a, TestWorkflows.Debounced, payload)
        end),
        Task.async(fn ->
          WorkflowEngine.start_workflow(engine_b, TestWorkflows.Debounced, payload)
        end)
      ]

      _results = Enum.map(tasks, &Task.await(&1, 5_000))

      # With work_claims unconfigured, no gate runs — both create. This documents
      # that work_claims must be configured for cross-node dedup to take effect.
      assert count_instances("Elixir.TestWorkflows.Debounced") == 2
    end
  end
end

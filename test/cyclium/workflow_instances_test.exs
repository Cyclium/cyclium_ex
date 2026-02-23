defmodule Cyclium.WorkflowInstancesTest do
  use ExUnit.Case, async: false

  alias Cyclium.WorkflowInstances

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
    end)

    :ok
  end

  describe "create/1" do
    test "inserts and returns a workflow instance" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        workflow_id: "Elixir.MyApp.Workflows.Test",
        trigger_ref: %{"order_id" => "ORD-1"},
        status: :running,
        step_states: %{"step_a" => %{"status" => "pending"}},
        started_at: now,
        created_at: now,
        updated_at: now
      }

      assert {:ok, instance} = WorkflowInstances.create(attrs)
      assert instance.workflow_id == "Elixir.MyApp.Workflows.Test"
      assert instance.status == :running
      assert instance.step_states["step_a"]["status"] == "pending"
    end
  end

  describe "get!/1" do
    test "retrieves by ID" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, instance} =
        WorkflowInstances.create(%{
          workflow_id: "test",
          status: :running,
          started_at: now,
          created_at: now
        })

      fetched = WorkflowInstances.get!(instance.id)
      assert fetched.id == instance.id
    end
  end

  describe "update_status/2" do
    test "transitions status and sets finished_at for terminal states" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, instance} =
        WorkflowInstances.create(%{
          workflow_id: "test",
          status: :running,
          started_at: now,
          created_at: now
        })

      {:ok, updated} = WorkflowInstances.update_status(instance.id, :done)
      assert updated.status == :done
      assert updated.finished_at != nil
    end

    test "does not set finished_at for non-terminal states" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, instance} =
        WorkflowInstances.create(%{
          workflow_id: "test",
          status: :running,
          started_at: now,
          created_at: now
        })

      {:ok, updated} = WorkflowInstances.update_status(instance.id, :blocked)
      assert updated.status == :blocked
      assert updated.finished_at == nil
    end
  end

  describe "update_step_states/2" do
    test "replaces step_states map" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, instance} =
        WorkflowInstances.create(%{
          workflow_id: "test",
          status: :running,
          step_states: %{"a" => %{"status" => "pending"}},
          started_at: now,
          created_at: now
        })

      new_states = %{"a" => %{"status" => "done", "result" => %{"ok" => true}}}
      {:ok, updated} = WorkflowInstances.update_step_states(instance.id, new_states)
      assert updated.step_states["a"]["status"] == "done"
    end
  end
end

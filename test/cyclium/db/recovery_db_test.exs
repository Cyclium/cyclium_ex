defmodule Cyclium.RecoveryDbTest do
  @moduledoc """
  Integration tests for Cyclium.Recovery sweep against a real SQLite sandbox.
  Covers compiled actor registry, dynamic actor DB fallback, and default behavior.
  """
  use Cyclium.DataCase

  alias Cyclium.Recovery
  alias Cyclium.Schemas.AgentDefinition

  # Compiled actor with recovery_policy: :restart on one expectation
  defmodule RestartActor do
    use Cyclium.Actor

    actor do
      identifier(:restart_actor)
      domain(:testing)

      expectation(:restartable_work,
        trigger: {:event, "work.requested"},
        recovery_policy: :restart
      )

      expectation(:not_restartable,
        trigger: {:event, "other.requested"}
      )
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.RecoveryTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.RecoveryTestPubSub)
    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
    end)

    :ok
  end

  describe "sweep with compiled actor registry" do
    test "restarts episode when actor has recovery_policy: :restart" do
      episode =
        insert_episode(%{
          actor_id: "restart_actor",
          expectation_id: "restartable_work",
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      registry = %{"restart_actor" => RestartActor}

      assert {:ok, counts} = Recovery.sweep(actor_registry: registry, stale_after_ms: 1)
      assert counts.restarted == 1
      assert counts.failed == 0

      assert episode.id in Cyclium.FakeRunner.enqueued_episodes()
    end

    test "fails episode when actor has no recovery_policy (default :fail)" do
      episode =
        insert_episode(%{
          actor_id: "restart_actor",
          expectation_id: "not_restartable",
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      registry = %{"restart_actor" => RestartActor}

      assert {:ok, counts} = Recovery.sweep(actor_registry: registry, stale_after_ms: 1)
      assert counts.failed == 1
      assert counts.restarted == 0

      failed = Repo.get!(Cyclium.Schemas.Episode, episode.id)
      assert failed.status == :failed
      assert failed.error_class == "orphaned"
    end

    test "fails episode when actor_id not in registry and not in DB" do
      insert_episode(%{
        actor_id: "unknown_actor",
        expectation_id: "unknown_exp",
        status: :running,
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

      assert {:ok, counts} = Recovery.sweep(actor_registry: %{}, stale_after_ms: 1)
      assert counts.failed == 1
    end
  end

  describe "sweep with dynamic actor DB fallback" do
    test "resolves recovery_policy from agent_definitions table" do
      # Insert a dynamic actor definition with recovery_policy: restart
      Repo.insert!(%AgentDefinition{
        id: Ecto.UUID.generate(),
        actor_id: "dynamic_monitor",
        domain: "testing",
        expectations:
          Jason.encode!([
            %{id: "check_status", recovery_policy: "restart"},
            %{id: "check_other"}
          ]),
        enabled: true,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      episode =
        insert_episode(%{
          actor_id: "dynamic_monitor",
          expectation_id: "check_status",
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      # No compiled registry — should fall back to DB
      assert {:ok, counts} = Recovery.sweep(actor_registry: %{}, stale_after_ms: 1)
      assert counts.restarted == 1

      assert episode.id in Cyclium.FakeRunner.enqueued_episodes()
    end

    test "defaults to :fail for dynamic actor expectation without recovery_policy" do
      Repo.insert!(%AgentDefinition{
        id: Ecto.UUID.generate(),
        actor_id: "dynamic_failover",
        domain: "testing",
        expectations: Jason.encode!([%{id: "some_work"}]),
        enabled: true,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      insert_episode(%{
        actor_id: "dynamic_failover",
        expectation_id: "some_work",
        status: :running,
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

      assert {:ok, counts} = Recovery.sweep(actor_registry: %{}, stale_after_ms: 1)
      assert counts.failed == 1
    end

    test "compiled registry takes precedence over DB definition" do
      # Insert a DB definition with recovery_policy: fail
      Repo.insert!(%AgentDefinition{
        id: Ecto.UUID.generate(),
        actor_id: "restart_actor",
        domain: "testing",
        expectations: Jason.encode!([%{id: "restartable_work", recovery_policy: "fail"}]),
        enabled: true,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      episode =
        insert_episode(%{
          actor_id: "restart_actor",
          expectation_id: "restartable_work",
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      # Compiled registry says :restart — should win over DB's :fail
      registry = %{"restart_actor" => RestartActor}
      assert {:ok, counts} = Recovery.sweep(actor_registry: registry, stale_after_ms: 1)
      assert counts.restarted == 1

      assert episode.id in Cyclium.FakeRunner.enqueued_episodes()
    end
  end

  describe "sweep with no options" do
    test "falls back to DB lookup for dynamic actors" do
      Repo.insert!(%AgentDefinition{
        id: Ecto.UUID.generate(),
        actor_id: "noarg_dynamic",
        domain: "testing",
        expectations: Jason.encode!([%{id: "auto_work", recovery_policy: "restart"}]),
        enabled: true,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      episode =
        insert_episode(%{
          actor_id: "noarg_dynamic",
          expectation_id: "auto_work",
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      # No actor_registry, no resolve_policy — should still check DB
      assert {:ok, counts} = Recovery.sweep(stale_after_ms: 1)
      assert counts.restarted == 1

      assert episode.id in Cyclium.FakeRunner.enqueued_episodes()
    end
  end

  describe "sweep with resolve_policy override" do
    test "custom resolve_policy takes precedence over everything" do
      insert_episode(%{
        actor_id: "restart_actor",
        expectation_id: "restartable_work",
        status: :running,
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

      # Custom policy says :fail, even though compiled actor says :restart
      assert {:ok, counts} =
               Recovery.sweep(
                 resolve_policy: fn _ep -> :fail end,
                 stale_after_ms: 1
               )

      assert counts.failed == 1
      assert counts.restarted == 0
    end
  end

  describe "reconcile_workflows" do
    test "replays episode.completed for done episode with running step_state" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      episode =
        insert_episode(%{
          actor_id: "wf_actor",
          expectation_id: "wf_step",
          status: :done,
          workflow_instance_id: wf_id = Ecto.UUID.generate(),
          workflow_step_id: "analyze",
          started_at: DateTime.add(now, -60, :second)
        })

      Repo.insert!(%Cyclium.Schemas.WorkflowInstance{
        id: wf_id,
        workflow_id: "test_workflow",
        status: :running,
        step_states: %{
          "analyze" => %{"status" => "running", "episode_id" => episode.id, "attempts" => 1}
        },
        started_at: now,
        created_at: now
      })

      # Subscribe to bus to capture the replayed event
      Cyclium.Bus.subscribe()

      assert {:ok, counts} = Recovery.reconcile_workflows()
      assert counts.replayed == 1

      ep_id = episode.id

      assert_receive {:bus, "episode.completed",
                      %{
                        episode_id: ^ep_id,
                        workflow_instance_id: ^wf_id,
                        workflow_step_id: "analyze"
                      }}
    end

    test "replays episode.failed for failed episode with running step_state" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      episode =
        insert_episode(%{
          actor_id: "wf_actor",
          expectation_id: "wf_step",
          status: :failed,
          workflow_instance_id: wf_id = Ecto.UUID.generate(),
          workflow_step_id: "summarize",
          started_at: DateTime.add(now, -60, :second)
        })

      Repo.insert!(%Cyclium.Schemas.WorkflowInstance{
        id: wf_id,
        workflow_id: "test_workflow",
        status: :running,
        step_states: %{
          "summarize" => %{"status" => "running", "episode_id" => episode.id, "attempts" => 1}
        },
        started_at: now,
        created_at: now
      })

      Cyclium.Bus.subscribe()

      assert {:ok, counts} = Recovery.reconcile_workflows()
      assert counts.replayed == 1

      ep_id = episode.id

      assert_receive {:bus, "episode.failed",
                      %{
                        episode_id: ^ep_id,
                        workflow_instance_id: ^wf_id,
                        workflow_step_id: "summarize"
                      }}
    end

    test "skips steps whose episodes are still running" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      episode =
        insert_episode(%{
          actor_id: "wf_actor",
          expectation_id: "wf_step",
          status: :running,
          workflow_instance_id: wf_id = Ecto.UUID.generate(),
          workflow_step_id: "analyze",
          started_at: DateTime.add(now, -60, :second)
        })

      Repo.insert!(%Cyclium.Schemas.WorkflowInstance{
        id: wf_id,
        workflow_id: "test_workflow",
        status: :running,
        step_states: %{
          "analyze" => %{"status" => "running", "episode_id" => episode.id, "attempts" => 1}
        },
        started_at: now,
        created_at: now
      })

      assert {:ok, counts} = Recovery.reconcile_workflows()
      assert counts.skipped == 1
      assert counts.replayed == 0
    end

    test "ignores workflow instances in terminal states" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Cyclium.Schemas.WorkflowInstance{
        id: Ecto.UUID.generate(),
        workflow_id: "test_workflow",
        status: :done,
        step_states: %{"analyze" => %{"status" => "done"}},
        started_at: now,
        created_at: now
      })

      Repo.insert!(%Cyclium.Schemas.WorkflowInstance{
        id: Ecto.UUID.generate(),
        workflow_id: "test_workflow",
        status: :failed,
        step_states: %{
          "analyze" => %{"status" => "running", "episode_id" => Ecto.UUID.generate()}
        },
        started_at: now,
        created_at: now
      })

      assert {:ok, counts} = Recovery.reconcile_workflows()
      assert counts.replayed == 0
      assert counts.skipped == 0
    end
  end
end

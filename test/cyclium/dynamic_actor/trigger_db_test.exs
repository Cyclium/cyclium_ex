defmodule Cyclium.DynamicActor.TriggerDbTest do
  @moduledoc """
  Integration test: a dynamic actor defined via JSON must actually wire up its
  triggers (event subscriptions + schedule timers). Regression test for the bug
  where JSON-decoded triggers (`%{type: "event", ...}` — atom keys, string
  values) matched none of the loader's trigger clauses, leaving the actor inert.

  Also covers that dynamic actors register in `Cyclium.ActorProcessRegistry`.
  """
  use Cyclium.DataCase

  alias Cyclium.DynamicActor.Loader
  alias Cyclium.Schemas.AgentDefinition

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.TriggerTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TriggerTestPubSub)
    start_supervised!({Registry, keys: :unique, name: Cyclium.ActorProcessRegistry})
    start_supervised!({DynamicSupervisor, name: Cyclium.ActorSupervisor, strategy: :one_for_one})

    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)
    :ok
  end

  test "JSON-defined event and schedule triggers are wired onto the actor" do
    Repo.insert!(%AgentDefinition{
      id: Ecto.UUID.generate(),
      actor_id: "trigger_fix_actor",
      domain: "testing",
      enabled: true,
      expectations:
        Jason.encode!([
          %{id: "evaluate", trigger: %{type: "event", event_type: "resource.check_requested"}},
          %{id: "tick", trigger: %{type: "schedule", interval_ms: 300_000}}
        ]),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert {:ok, pid} = Loader.load("trigger_fix_actor")

    state = :sys.get_state(pid)

    evaluate = state.expectations[:evaluate]
    assert evaluate.trigger == {:event, "resource.check_requested"}
    assert "resource.check_requested" in evaluate.subscribes_to

    tick = state.expectations[:tick]
    assert tick.trigger == {:schedule, 300_000}
    # A schedule timer is armed for the scheduled expectation.
    assert Map.has_key?(state.timers, :tick)
  end

  test "a dynamic actor registers in the actor process registry under its id" do
    Repo.insert!(%AgentDefinition{
      id: Ecto.UUID.generate(),
      actor_id: "registered_dynamic_actor",
      domain: "testing",
      enabled: true,
      expectations:
        Jason.encode!([
          %{id: "evaluate", trigger: %{type: "event", event_type: "x.happened"}}
        ]),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert {:ok, pid} = Loader.load("registered_dynamic_actor")

    assert [{^pid, _}] =
             Registry.lookup(Cyclium.ActorProcessRegistry, "registered_dynamic_actor")
  end
end

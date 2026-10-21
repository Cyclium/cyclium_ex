defmodule Cyclium.ActorShedDbTest do
  @moduledoc """
  An actor with `episode_overflow(:shed_oldest)` cancels its oldest queued run
  to make room. The `episode.canceled` it broadcasts must name that run's
  subject, like every other run-ending event, so a subscriber matching on it
  sees the run end even though it never started.
  """
  use Cyclium.DataCase

  defmodule ShedActor do
    use Cyclium.Actor

    actor do
      identifier(:shed_actor)
      domain(:testing)
      max_concurrent_episodes(1)
      episode_overflow(:shed_oldest)

      expectation(:do_work, trigger: {:event, "work.requested"})
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.ActorShedTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.ActorShedTestPubSub)
    start_supervised!(Cyclium.FakeRunner)
    Cyclium.FakeRunner.reset()
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
    end)

    :ok
  end

  test "episode.canceled for a shed run carries its expectation_id and trigger_ref" do
    {:ok, pid} = ShedActor.start_link(name: :shed_actor_test)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    queued =
      insert_episode(%{
        actor_id: "shed_actor",
        expectation_id: "do_work",
        trigger_ref: %{"payload" => %{"thing_id" => "t-1"}}
      })

    # Fill the one slot, then hold the second run in the queue.
    send(pid, {:recover_episode, Ecto.UUID.generate()})
    send(pid, {:recover_episode, queued.id})
    assert :queue.len(:sys.get_state(pid).queued_episodes) == 1

    Cyclium.Bus.subscribe("episode.canceled")
    send(pid, {:force_fire, :do_work})

    queued_id = queued.id
    assert_receive {:bus, "episode.canceled", %{episode_id: ^queued_id} = payload}, 1_000
    assert payload.reason == :shed_oldest
    assert payload.status == :canceled
    assert payload.expectation_id == "do_work"
    assert Cyclium.Bus.subject(payload, "thing_id") == "t-1"

    assert Repo.get!(Cyclium.Schemas.Episode, queued_id).status == :canceled

    GenServer.stop(pid)
  end
end

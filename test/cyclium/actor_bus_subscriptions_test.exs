defmodule Cyclium.ActorBusSubscriptionsTest do
  @moduledoc """
  An actor subscribes to the event types its expectations listen for and the
  run-ending events, not the whole bus.
  """
  use ExUnit.Case, async: false

  defmodule EventActor do
    use Cyclium.Actor

    actor do
      domain(:testing)

      expectation(:on_alert,
        trigger: {:event, "alert.fired"},
        description: "React to alerts"
      )

      expectation(:after_run,
        trigger: {:event, "episode.completed"},
        description: "Chain off another run"
      )
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.ActorBusTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.ActorBusTestPubSub)
    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)
    :ok
  end

  defp topics(pid), do: pid |> then(&Registry.keys(Cyclium.ActorBusTestPubSub, &1)) |> Enum.sort()

  test "subscribes to its expectations' types and the run-ending events, once each" do
    {:ok, pid} = EventActor.start_link(name: :actor_bus_subs)

    assert topics(pid) == [
             "cyclium:events:alert.fired",
             "cyclium:events:episode.canceled",
             "cyclium:events:episode.completed",
             "cyclium:events:episode.failed"
           ]

    GenServer.stop(pid)
  end

  test "a reconcile moves the subscriptions with the expectations" do
    {:ok, pid} = EventActor.start_link(name: :actor_bus_reconcile)

    config = EventActor.__cyclium_config__()
    GenServer.cast(pid, {:reconcile, config, [{:on_deploy, [trigger: {:event, "deploy.done"}]}]})
    :sys.get_state(pid)

    assert topics(pid) == [
             "cyclium:events:deploy.done",
             "cyclium:events:episode.canceled",
             "cyclium:events:episode.completed",
             "cyclium:events:episode.failed"
           ]

    GenServer.stop(pid)
  end
end

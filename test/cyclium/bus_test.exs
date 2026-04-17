defmodule Cyclium.BusTest do
  use ExUnit.Case

  setup do
    # Start a PubSub for testing
    start_supervised!({Phoenix.PubSub, name: Cyclium.TestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TestPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
    end)

    :ok
  end

  test "publish/subscribe delivers events" do
    Cyclium.Bus.subscribe()
    Cyclium.Bus.publish("test.event", %{data: "hello"})

    assert_receive {:bus, "test.event", %{data: "hello"}}
  end

  test "broadcast delivers to both global and specific topic" do
    Cyclium.Bus.subscribe()
    Cyclium.Bus.subscribe("specific.event")
    Cyclium.Bus.broadcast("specific.event", %{value: 42})

    # Should receive on global topic
    assert_receive {:bus, "specific.event", %{value: 42}}
    # Should also receive on specific topic (second copy)
    assert_receive {:bus, "specific.event", %{value: 42}}
  end

  test "subscribe to specific event type only receives matching events" do
    Cyclium.Bus.subscribe("wanted.event")
    Cyclium.Bus.broadcast("wanted.event", %{yes: true})
    Cyclium.Bus.broadcast("unwanted.event", %{no: true})

    assert_receive {:bus, "wanted.event", %{yes: true}}
    refute_receive {:bus, "unwanted.event", _}
  end

  test "publish returns error when no pubsub configured" do
    Application.delete_env(:cyclium, :pubsub)
    assert {:error, :no_pubsub} = Cyclium.Bus.publish("test", %{})
  end

  test "runtime_events returns the known list" do
    events = Cyclium.Bus.runtime_events()
    assert "episode.completed" in events
    assert "finding.raised" in events
    assert "episode.queued" in events
    assert "episode.started" in events
  end
end

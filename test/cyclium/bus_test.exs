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

  test "publish reaches the event type's topic as broadcast does" do
    Cyclium.Bus.subscribe("domain.event")
    Cyclium.Bus.publish("domain.event", %{n: 1})

    assert_receive {:bus, "domain.event", %{n: 1}}
  end

  describe "scoped topics" do
    @payload %{
      episode_id: "ep-1",
      conversation_id: "conv-1",
      actor_id: "actor_a",
      workflow_instance_id: "wf-1"
    }

    test "each id the payload names has its own topic" do
      for scope <- [episode: "ep-1", conversation: "conv-1", actor: "actor_a", workflow: "wf-1"] do
        Cyclium.Bus.subscribe([scope])
        Cyclium.Bus.broadcast("episode.completed", @payload)

        assert_receive {:bus, "episode.completed", @payload}
        refute_receive {:bus, _, _}
        Cyclium.Bus.unsubscribe([scope])
      end
    end

    test "another id's events do not arrive" do
      Cyclium.Bus.subscribe(episode: "ep-2")
      Cyclium.Bus.broadcast("episode.step_journaled", @payload)

      refute_receive {:bus, _, _}
    end

    test "an atom actor id matches the payload's string id" do
      Cyclium.Bus.subscribe(actor: :actor_a)
      Cyclium.Bus.broadcast("episode.dropped", %{actor_id: "actor_a", expectation_id: "x"})

      assert_receive {:bus, "episode.dropped", _}
    end

    test "string payload keys are read too" do
      Cyclium.Bus.subscribe(conversation: "conv-9")
      Cyclium.Bus.broadcast("conversation.resolved", %{"conversation_id" => "conv-9"})

      assert_receive {:bus, "conversation.resolved", _}
    end

    test "an event without the id is not sent to that kind of topic" do
      Cyclium.Bus.subscribe(episode: "")
      Cyclium.Bus.broadcast("episode.dropped", %{actor_id: "actor_a"})

      refute_receive {:bus, _, _}
    end

    test "an unknown scope raises" do
      assert_raise ArgumentError, ~r/unknown Bus scope :run/, fn ->
        Cyclium.Bus.subscribe(run: "ep-1")
      end
    end
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

  describe "subject/2" do
    test "reads trigger_ref[\"payload\"][key] from an event payload" do
      payload = %{episode_id: "e-1", trigger_ref: %{"payload" => %{"thing_id" => "t-1"}}}
      assert Cyclium.Bus.subject(payload, "thing_id") == "t-1"
    end

    test "is nil when the key, the payload, or the trigger_ref is missing" do
      assert Cyclium.Bus.subject(%{trigger_ref: %{"payload" => %{}}}, "thing_id") == nil
      assert Cyclium.Bus.subject(%{trigger_ref: %{}}, "thing_id") == nil
      assert Cyclium.Bus.subject(%{trigger_ref: nil}, "thing_id") == nil
      assert Cyclium.Bus.subject(%{}, "thing_id") == nil
    end
  end
end

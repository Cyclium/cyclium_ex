defmodule Cyclium.Bus do
  @moduledoc """
  Event pub/sub that connects actors without coupling.

  Two event layers:
  - Layer A: Domain events (emitted by your application)
  - Layer B: Runtime events (emitted by Cyclium internals)

  Built on Phoenix.PubSub. The consuming app provides the PubSub process
  via `Cyclium.Supervisor` opts.
  """

  @topic "cyclium:events"

  @runtime_events [
    "expectation.due", "expectation.triggered",
    "finding.raised", "finding.updated", "finding.cleared",
    "work.requested",
    "output.proposed", "output.delivered",
    "approval.requested", "approval.resolved",
    "spec.updated", "agent.state_changed",
    "episode.completed", "episode.failed", "episode.queued",
    "episode.dropped", "episode.canceled"
  ]

  def runtime_events, do: @runtime_events

  @doc """
  Publish an event to the bus. All subscribers receive `{:bus, event_type, payload}`.
  """
  def publish(event_type, payload \\ %{}) when is_binary(event_type) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.broadcast(pubsub, @topic, {:bus, event_type, payload})
    end
  end

  @doc """
  Subscribe the calling process to all bus events.
  Messages arrive as `{:bus, event_type, payload}`.
  """
  def subscribe do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.subscribe(pubsub, @topic)
    end
  end

  @doc """
  Subscribe to a specific event type topic.
  Messages arrive as `{:bus, event_type, payload}`.
  """
  def subscribe(event_type) when is_binary(event_type) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.subscribe(pubsub, "#{@topic}:#{event_type}")
    end
  end

  @doc """
  Publish to both the global topic and the event-specific topic,
  so both broad and targeted subscribers receive the event.
  """
  def broadcast(event_type, payload \\ %{}) when is_binary(event_type) do
    case pubsub() do
      nil ->
        {:error, :no_pubsub}

      pubsub ->
        msg = {:bus, event_type, payload}
        Phoenix.PubSub.broadcast(pubsub, @topic, msg)
        Phoenix.PubSub.broadcast(pubsub, "#{@topic}:#{event_type}", msg)
    end
  end

  defp pubsub do
    Application.get_env(:cyclium, :pubsub)
  end
end

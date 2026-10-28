defmodule Cyclium.Bus do
  @moduledoc """
  Event pub/sub that connects actors without coupling.

  Two event layers:
  - Layer A: Domain events (emitted by your application)
  - Layer B: Runtime events (emitted by Cyclium internals)

  Built on Phoenix.PubSub. The consuming app provides the PubSub process
  via `Cyclium.Supervisor` opts.

  Runtime event payloads are atom-keyed maps (`%{episode_id: ..., actor_id:
  ...}`), and PubSub delivers the term unchanged, on any node — match
  `payload[:actor_id]`, not `payload["actor_id"]`. The exception is what lies
  inside `trigger_ref`: it is the episode's stored JSON map, so its keys are
  strings. Read it with `subject/2`.
  """

  @topic "cyclium:events"

  @runtime_events [
    "expectation.due",
    "expectation.triggered",
    "finding.raised",
    "finding.updated",
    "finding.cleared",
    "work.requested",
    "output.proposed",
    "output.delivered",
    "approval.requested",
    "approval.resolved",
    "spec.updated",
    "agent.state_changed",
    "episode.completed",
    "episode.failed",
    "episode.queued",
    "episode.started",
    "episode.dropped",
    "episode.canceled",
    "workflow.started",
    "workflow.completed",
    "workflow.failed"
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

  @doc """
  Read a value from an episode event's trigger subject.

  Every episode lifecycle event — `episode.queued`, `episode.started`,
  `episode.completed`, `episode.failed`, `episode.canceled` and
  `episode.interrupted` — carries the run's `expectation_id` and `trigger_ref`,
  the subject the run is about, whichever path ends the run: the runner, a
  crashed or exited task, a recovery sweep, a replayed workflow step, a cancel,
  or a queued run shed at capacity. (`episode.dropped` names no episode — the
  run was never created — so it carries `actor_id` and `expectation_id` only.) This reads
  `trigger_ref["payload"][key]` so a subscriber can tell which subject an event
  names without hand-rolling the nested access or a DB read. Returns `nil` when the payload has no `trigger_ref`, no `"payload"`, or
  no such `key`.

      def handle_info({:bus, "episode.completed", payload}, socket) do
        case Cyclium.Bus.subject(payload, "thing_id") do
          nil -> {:noreply, socket}
          thing_id -> {:noreply, refresh_row(socket, thing_id)}
        end
      end
  """
  def subject(payload, key) when is_map(payload) do
    case payload[:trigger_ref] || payload["trigger_ref"] do
      %{"payload" => inner} when is_map(inner) -> inner[key]
      _ -> nil
    end
  end

  @private_trigger_keys ~w(principal message history)

  @doc """
  The part of an episode's `trigger_ref` that lifecycle broadcasts carry.

  Every `Cyclium.Bus.subscribe/0` subscriber in the cluster receives every
  lifecycle event, so the conversation turn's `message`, the `principal` map and
  any `history` are dropped before broadcast; the subject `payload` and the
  correlation ids stay, so `subject/2` keeps working. Read the full
  `trigger_ref` from the episode row when a consumer needs it.
  """
  @spec public_trigger_ref(map() | nil) :: map() | nil
  def public_trigger_ref(nil), do: nil

  def public_trigger_ref(ref) when is_map(ref) do
    Map.drop(ref, @private_trigger_keys ++ Enum.map(@private_trigger_keys, &String.to_atom/1))
  end

  def public_trigger_ref(other), do: other

  @cancel_topic_prefix "cyclium:episode_cancel:"

  @doc """
  Subscribe the calling process to cancel requests for one episode.

  A running `EpisodeTask` subscribes so a "stop" reaches it on whatever node
  runs the episode (PubSub is cluster-wide), landing as `{:cyclium_cancel,
  reason}` handled at the next step boundary.
  """
  def subscribe_cancel(episode_id) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.subscribe(pubsub, @cancel_topic_prefix <> to_string(episode_id))
    end
  end

  @doc """
  Broadcast a cancel request for an episode to whichever node runs it. Backs
  `Cyclium.Episodes.request_cancel/2`.
  """
  def publish_cancel(episode_id, reason) do
    case pubsub() do
      nil ->
        {:error, :no_pubsub}

      pubsub ->
        Phoenix.PubSub.broadcast(
          pubsub,
          @cancel_topic_prefix <> to_string(episode_id),
          {:cyclium_cancel, reason}
        )
    end
  end

  defp pubsub do
    Application.get_env(:cyclium, :pubsub)
  end
end

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

  ## Topics

  Every event goes to the global topic (`subscribe/0`) and to its event type's
  topic (`subscribe/1` with a type). It also goes to a topic for each id its
  payload names, so a view can subscribe to one run, conversation, actor or
  workflow and receive nothing else:

      Cyclium.Bus.subscribe(episode: episode_id)
      Cyclium.Bus.subscribe(conversation: conversation_id)
      Cyclium.Bus.subscribe(actor: :my_actor)
      Cyclium.Bus.subscribe(workflow: workflow_instance_id)

  The ids are read from the payload's `episode_id`, `conversation_id`,
  `actor_id` and `workflow_instance_id`. An event without one of them is not
  sent to that kind of topic: `episode.dropped`, for one, names no episode and
  reaches only its actor's topic. Messages keep the `{:bus, event_type,
  payload}` shape on every topic.

  Subscribe before loading the state a view shows, so an event that lands in
  between is not lost. A process subscribed to two topics that one event
  reaches receives it once per topic. Under a clustered PubSub, each topic an
  event reaches is a broadcast to every node.
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

  @scopes [
    episode: :episode_id,
    conversation: :conversation_id,
    actor: :actor_id,
    workflow: :workflow_instance_id
  ]

  @doc """
  Publish an event to the bus. The same as `broadcast/2`: subscribers of the
  global topic, the event type's topic and each scoped topic the payload names
  receive `{:bus, event_type, payload}`.
  """
  def publish(event_type, payload \\ %{}) when is_binary(event_type),
    do: broadcast(event_type, payload)

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
  Subscribe to one event type's topic, `subscribe("episode.completed")`, or to
  the events that name one episode, conversation, actor or workflow instance:
  `subscribe(episode: id)`, `subscribe(conversation: id)`,
  `subscribe(actor: id)`, `subscribe(workflow: id)` (one scope per call).
  Messages arrive as `{:bus, event_type, payload}`.
  """
  def subscribe(event_type) when is_binary(event_type) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.subscribe(pubsub, "#{@topic}:#{event_type}")
    end
  end

  def subscribe([{scope, id}]) when is_atom(scope) and not is_nil(id) do
    unless Keyword.has_key?(@scopes, scope) do
      raise ArgumentError,
            "unknown Bus scope #{inspect(scope)}; expected one of #{inspect(Keyword.keys(@scopes))}"
    end

    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.subscribe(pubsub, scope_topic(scope, id))
    end
  end

  @doc "Stop receiving the events `subscribe/1` subscribed to (a type or a scope)."
  def unsubscribe(event_type) when is_binary(event_type) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.unsubscribe(pubsub, "#{@topic}:#{event_type}")
    end
  end

  def unsubscribe([{scope, id}]) when is_atom(scope) and not is_nil(id) do
    case pubsub() do
      nil -> {:error, :no_pubsub}
      pubsub -> Phoenix.PubSub.unsubscribe(pubsub, scope_topic(scope, id))
    end
  end

  @doc """
  Publish to the global topic, the event type's topic, and the scoped topic of
  each id the payload names (see "Topics" above).
  """
  def broadcast(event_type, payload \\ %{}) when is_binary(event_type) do
    case pubsub() do
      nil ->
        {:error, :no_pubsub}

      pubsub ->
        msg = {:bus, event_type, payload}
        Phoenix.PubSub.broadcast(pubsub, @topic, msg)
        Phoenix.PubSub.broadcast(pubsub, "#{@topic}:#{event_type}", msg)

        for topic <- scoped_topics(payload) do
          Phoenix.PubSub.broadcast(pubsub, topic, msg)
        end

        :ok
    end
  end

  defp scoped_topics(payload) when is_map(payload) do
    for {scope, key} <- @scopes,
        id = payload[key] || payload[Atom.to_string(key)],
        not is_nil(id),
        do: scope_topic(scope, id)
  end

  defp scoped_topics(_payload), do: []

  defp scope_topic(scope, id), do: "cyclium:#{scope}:#{id}"

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

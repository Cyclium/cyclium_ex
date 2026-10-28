defmodule Cyclium.Telemetry do
  @moduledoc """
  Telemetry integration for Cyclium.

  ## Events

  ### Episode lifecycle

      [:cyclium, :episode, :started]      — %{episode_id, actor_id}
      [:cyclium, :episode, :completed]    — %{episode_id, actor_id, output_count, finding_count}
      [:cyclium, :episode, :failed]       — %{episode_id, actor_id, error_class}
      [:cyclium, :episode, :blocked]      — %{episode_id, actor_id, conversation_id, reason}
      [:cyclium, :episode, :resumed]      — %{episode_id, actor_id}
      [:cyclium, :episode, :dropped]      — %{actor_id, expectation_id}
      [:cyclium, :episode, :canceled]     — %{episode_id, actor_id, reason}
      [:cyclium, :episode, :sampled_out]  — %{actor_id, expectation_id}

  ### Step events

      [:cyclium, :step, :tool_call]       — %{tool, action, episode_id, actor_id, conversation_id}
      [:cyclium, :step, :synthesis, :start] — meas %{count, system_time}, meta %{episode_id, actor_id, conversation_id}
      [:cyclium, :step, :synthesis]       — meas %{duration_ms, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, total_tokens}, meta %{episode_id, actor_id, conversation_id, model, usage_reported}
      [:cyclium, :step, :observation]     — %{actor_id, episode_id}

  `[:cyclium, :step, :synthesis, :start]` fires as the request goes out;
  `[:cyclium, :step, :synthesis]` fires when it returns. `total_tokens` counts
  cached input (`cache_*_input_tokens`) as well as `input_tokens` and
  `output_tokens`.

  `usage_reported` (boolean) distinguishes a genuine zero-token synthesis from a
  synthesizer that omitted its `usage` key — the latter also logs a warning when
  the result names a model, since the missing figure otherwise undercounts
  budgets and cost telemetry silently.

  ### Checkpoint events

      [:cyclium, :checkpoint, :save_failed] — %{count}, meta: %{episode_id, actor_id, expectation_id, phase, error_class}

  Emitted when a checkpoint write could not be persisted (most often state that
  doesn't survive a JSON round-trip — see `Cyclium.CheckpointSchema.json_plain?/1`).
  The episode continues, but resume will fall back to a fresh `init/2` instead of
  restoring progress, so a spike here is worth alerting on.

  ### Actor events

      [:cyclium, :actor, :event_received] — %{actor_id, event_type}
      [:cyclium, :actor, :overflow]       — %{actor_id, policy, expectation_id}

  `:event_received` fires only when the event is *relevant* to the actor — one
  of its expectations subscribes to it, or it is a lifecycle transition of the
  actor's own episode. Every actor is subscribed to the whole bus, so an actor
  that merely observes another actor's broadcast and drops it is not counted as
  having "received" it.

  ### Output events

      [:cyclium, :output, :delivered]     — %{type, dedupe_key, ref}
      [:cyclium, :output, :failed]        — %{type, dedupe_key, reason}
      [:cyclium, :output, :deduplicated]  — %{type, dedupe_key}

  ### Finding events

      [:cyclium, :finding, :raised]       — %{finding_key, actor_id, class}
      [:cyclium, :finding, :cleared]      — %{finding_key, actor_id, class}
      [:cyclium, :finding, :expired]      — %{count}
      [:cyclium, :finding, :escalated]    — %{finding_key, class, from, to}

  ### Finding sweep events

      [:cyclium, :finding_sweep, :completed] — %{duration_ms, expired_count, escalated_count}, meta: %{node}
      [:cyclium, :finding_sweep, :failed]    — %{duration_ms}, meta: %{node, reason}

  ### Work claims events

      [:cyclium, :work_claims, :acquired]     — %{count, duration_ms}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :steal]        — %{count, duration_ms}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :busy]         — %{count, duration_ms}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :renewed]      — %{count}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :renew_failed] — %{count}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :completed]    — %{count}, meta: %{dedupe_key, owner_node}
      [:cyclium, :work_claims, :failed]       — %{count}, meta: %{dedupe_key, owner_node}


  ### Workflow events

      [:cyclium, :workflow, :started]        — %{workflow_id, instance_id}
      [:cyclium, :workflow, :step_started]   — %{workflow_id, instance_id, step_id, episode_id}
      [:cyclium, :workflow, :step_completed] — %{workflow_id, instance_id, step_id}
      [:cyclium, :workflow, :step_failed]    — %{workflow_id, instance_id, step_id}
      [:cyclium, :workflow, :step_retried]   — %{workflow_id, instance_id, step_id, attempt}
      [:cyclium, :workflow, :completed]      — %{workflow_id, instance_id}
      [:cyclium, :workflow, :failed]         — %{workflow_id, instance_id, step_id}
      [:cyclium, :workflow, :duplicate_blocked] — %{count}, meta: %{workflow_id, subject_value, owner_node}

  ### Conversation events

      [:cyclium, :conversation, :started]             — %{conversation_id, actor_id}
      [:cyclium, :conversation, :claimed]              — %{conversation_id, principal_id}
      [:cyclium, :conversation, :resolved]             — %{conversation_id, outcome}
      [:cyclium, :conversation, :abandoned]            — %{conversation_id, reason}
      [:cyclium, :conversation, :timed_out]            — %{conversation_id}
      [:cyclium, :conversation, :awaiting_participant] — %{conversation_id, actor_id}

  ## Background work spans

  The events above are point-in-time signals. Several of Cyclium's background
  workers are *self-scheduled* — they run on their own timer (or as a detached
  startup task) rather than in response to a caller — so the work they do holds
  no caller context. A host application that traces its database work therefore
  sees each query such a worker runs as its own parentless root span, with
  nothing tying the queries of one tick together or recording how long the tick
  took.

  To let a host hold a single trace span open across a whole tick, each of these
  workers wraps its work in `:telemetry.span/3` via `span/3`, emitting a
  `:start`/`:stop` (or `:exception`) pair under one shared event prefix:

      [:cyclium, :background_work, :start]     — meas %{system_time, monotonic_time},
                                                 meta %{work, node, ...scope}
      [:cyclium, :background_work, :stop]      — meas %{duration, monotonic_time},
                                                 meta %{work, node, ...scope, result}
      [:cyclium, :background_work, :exception] — meas %{duration, monotonic_time},
                                                 meta %{work, node, ...scope, kind, reason, stacktrace}

  `work` is a low-cardinality atom naming the worker (e.g. `:trigger_requests_poll`,
  `:recovery_sweep`, `:finding_sweep`, `:work_claims_heartbeat`); a consumer opens
  its trace span on `:start`, names it by `work`, and ends it on `:stop`, so the
  queries in between nest beneath it. `result` (when present) is a small map of
  low-cardinality numeric counts summarising the tick.

  These are a different *kind* of event from those above — a paired span rather
  than a business signal — so they are deliberately **not** in `events/0` and are
  listed separately by `span_events/0`. A logging consumer attaching to `events/0`
  is unaffected by them; a tracing consumer attaches to `span_events/0`.

  ## Usage

      # Attach a simple logger for development
      Cyclium.Telemetry.attach_default_logger()

      # Or attach your own handler to specific events
      :telemetry.attach("my-handler", [:cyclium, :output, :delivered], &MyHandler.handle/4, %{})
  """

  @events [
    # Episode lifecycle
    [:cyclium, :episode, :started],
    [:cyclium, :episode, :completed],
    [:cyclium, :episode, :failed],
    [:cyclium, :episode, :blocked],
    [:cyclium, :episode, :resumed],
    [:cyclium, :episode, :dropped],
    [:cyclium, :episode, :canceled],
    [:cyclium, :episode, :sampled_out],
    # Steps
    [:cyclium, :step, :tool_call],
    [:cyclium, :step, :synthesis, :start],
    [:cyclium, :step, :synthesis],
    [:cyclium, :step, :observation],
    # Actor
    [:cyclium, :actor, :event_received],
    [:cyclium, :actor, :overflow],
    # Outputs
    [:cyclium, :output, :delivered],
    [:cyclium, :output, :failed],
    [:cyclium, :output, :deduplicated],
    # Findings
    [:cyclium, :finding, :raised],
    [:cyclium, :finding, :cleared],
    [:cyclium, :finding, :expired],
    [:cyclium, :finding, :escalated],
    # Service levels
    [:cyclium, :service_levels, :breach],
    # Circuit breaker
    [:cyclium, :circuit_breaker, :opened],
    [:cyclium, :circuit_breaker, :closed],
    [:cyclium, :circuit_breaker, :half_open],
    [:cyclium, :circuit_breaker, :rejected],
    # Finding sweep
    [:cyclium, :finding_sweep, :completed],
    [:cyclium, :finding_sweep, :failed],
    # Recovery sweep (re-enqueues stale running episodes)
    [:cyclium, :recovery, :sweep],
    # Work claims
    [:cyclium, :work_claims, :acquired],
    [:cyclium, :work_claims, :steal],
    [:cyclium, :work_claims, :busy],
    [:cyclium, :work_claims, :renewed],
    [:cyclium, :work_claims, :renew_failed],
    [:cyclium, :work_claims, :completed],
    [:cyclium, :work_claims, :failed],
    # Workflows
    [:cyclium, :workflow, :started],
    [:cyclium, :workflow, :step_started],
    [:cyclium, :workflow, :step_completed],
    [:cyclium, :workflow, :step_failed],
    [:cyclium, :workflow, :step_retried],
    [:cyclium, :workflow, :completed],
    [:cyclium, :workflow, :failed],
    [:cyclium, :workflow, :step_reused],
    [:cyclium, :workflow, :duplicate_blocked],
    # Conversations
    [:cyclium, :conversation, :started],
    [:cyclium, :conversation, :claimed],
    [:cyclium, :conversation, :resolved],
    [:cyclium, :conversation, :abandoned],
    [:cyclium, :conversation, :timed_out],
    [:cyclium, :conversation, :awaiting_participant]
  ]

  # Shared prefix for the span-shaped background-work events. Kept out of
  # @events on purpose — see the "Background work spans" section above.
  @background_work_prefix [:cyclium, :background_work]

  @span_events [
    @background_work_prefix ++ [:start],
    @background_work_prefix ++ [:stop],
    @background_work_prefix ++ [:exception]
  ]

  @doc "Returns the list of all Cyclium (point-in-time) telemetry event names."
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc """
  Returns the span-shaped background-work event names (`:start`/`:stop`/`:exception`).

  These are the paired tracing events emitted by `span/3`, kept separate from
  `events/0` so a logging consumer never has to filter them out and a tracing
  consumer can attach to exactly these.
  """
  @spec span_events() :: [list(atom())]
  def span_events, do: @span_events

  @doc """
  Wrap a self-scheduled unit of background work in a span so a host application
  can hold a trace span open across it (see "Background work spans" above).

  `work` is a low-cardinality atom naming the worker. `metadata` carries the
  low-cardinality scope tags for the span (e.g. `:node`, `:source_stack`,
  `:source_env`) and rides on all three events. `fun` runs the work and returns
  `{result, stop_metadata}` in the shape `:telemetry.span/3` expects; the
  returned `result` is passed straight back to the caller.

      Cyclium.Telemetry.span(:trigger_requests_poll, %{node: node}, fn ->
        count = do_poll()
        {:ok, %{result: %{request_count: count}}}
      end)
  """
  @spec span(atom(), map(), (-> {result, map()})) :: result when result: term()
  def span(work, metadata, fun) when is_atom(work) and is_function(fun, 0) do
    start_metadata = Map.put(metadata, :work, work)

    # `:telemetry.span/3` carries `start_metadata` onto the `:exception` event but
    # NOT onto `:stop` (there, only what the function returns). Merge it back in so
    # `:stop` is self-describing too — `work` and the scope tags ride on all three.
    :telemetry.span(@background_work_prefix, start_metadata, fn ->
      case fun.() do
        {result, stop_metadata} ->
          {result, Map.merge(start_metadata, stop_metadata)}

        {result, extra_measurements, stop_metadata} ->
          {result, extra_measurements, Map.merge(start_metadata, stop_metadata)}
      end
    end)
  end

  @doc """
  Attach a Logger-based handler for all Cyclium telemetry events.
  Useful for development and debugging.
  """
  @spec attach_default_logger(atom()) :: :ok | {:error, :already_exists}
  def attach_default_logger(log_level \\ :debug) do
    :telemetry.attach_many(
      "cyclium-default-logger",
      @events,
      &__MODULE__.handle_event/4,
      %{log_level: log_level}
    )
  end

  @doc false
  def handle_event(
        [:cyclium, :actor, :event_received],
        _measurements,
        %{event_type: "episode.step_journaled"},
        _config
      ),
      do: :ok

  def handle_event(event, measurements, metadata, %{log_level: level}) do
    require Logger
    Logger.log(level, "[Cyclium] #{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
  end
end

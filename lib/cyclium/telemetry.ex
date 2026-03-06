defmodule Cyclium.Telemetry do
  @moduledoc """
  Telemetry integration for Cyclium.

  ## Events

  ### Episode lifecycle

      [:cyclium, :episode, :started]      — %{episode_id, actor_id}
      [:cyclium, :episode, :completed]    — %{episode_id, actor_id, output_count, finding_count}
      [:cyclium, :episode, :failed]       — %{episode_id, actor_id, error_class}
      [:cyclium, :episode, :blocked]      — %{episode_id, actor_id}
      [:cyclium, :episode, :resumed]      — %{episode_id, actor_id}
      [:cyclium, :episode, :dropped]      — %{actor_id, expectation_id}
      [:cyclium, :episode, :queued]       — %{episode_id, actor_id}
      [:cyclium, :episode, :canceled]     — %{episode_id, actor_id, reason}
      [:cyclium, :episode, :sampled_out]  — %{actor_id, expectation_id}

  ### Step events

      [:cyclium, :step, :tool_call]       — %{tool, action, episode_id}
      [:cyclium, :step, :synthesis]       — %{episode_id}
      [:cyclium, :step, :output]          — %{type, status, episode_id}
      [:cyclium, :step, :observation]     — %{actor_id, episode_id}

  ### Budget events

      [:cyclium, :budget, :tokens]        — %{episode_id, used, max, pct}
      [:cyclium, :budget, :turns]         — %{episode_id, used, max, pct}

  ### Actor events

      [:cyclium, :actor, :event_received] — %{actor_id, event_type}
      [:cyclium, :actor, :overflow]       — %{actor_id, policy, expectation_id}

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

  ### Phase events

      [:cyclium, :phase, :changed]        — %{from, to, episode_id, actor_id}

  ### Guardrail events

      [:cyclium, :guardrail, :triggered]  — %{rule, episode_id, actor_id, detail}

  ### Workflow events

      [:cyclium, :workflow, :started]        — %{workflow_id, instance_id}
      [:cyclium, :workflow, :step_started]   — %{workflow_id, instance_id, step_id, episode_id}
      [:cyclium, :workflow, :step_completed] — %{workflow_id, instance_id, step_id}
      [:cyclium, :workflow, :step_failed]    — %{workflow_id, instance_id, step_id}
      [:cyclium, :workflow, :step_retried]   — %{workflow_id, instance_id, step_id, attempt}
      [:cyclium, :workflow, :completed]      — %{workflow_id, instance_id}
      [:cyclium, :workflow, :failed]         — %{workflow_id, instance_id, step_id}

  ### Conversation events

      [:cyclium, :conversation, :started]             — %{conversation_id, actor_id}
      [:cyclium, :conversation, :claimed]              — %{conversation_id, principal_id}
      [:cyclium, :conversation, :resolved]             — %{conversation_id, outcome}
      [:cyclium, :conversation, :abandoned]            — %{conversation_id, reason}
      [:cyclium, :conversation, :timed_out]            — %{conversation_id}
      [:cyclium, :conversation, :awaiting_participant] — %{conversation_id, actor_id}

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
    [:cyclium, :episode, :queued],
    [:cyclium, :episode, :canceled],
    [:cyclium, :episode, :sampled_out],
    # Steps
    [:cyclium, :step, :tool_call],
    [:cyclium, :step, :synthesis],
    [:cyclium, :step, :output],
    [:cyclium, :step, :observation],
    # Budget
    [:cyclium, :budget, :tokens],
    [:cyclium, :budget, :turns],
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
    # Phase
    [:cyclium, :phase, :changed],
    # Service levels
    [:cyclium, :service_levels, :breach],
    # Circuit breaker
    [:cyclium, :circuit_breaker, :opened],
    [:cyclium, :circuit_breaker, :closed],
    [:cyclium, :circuit_breaker, :half_open],
    [:cyclium, :circuit_breaker, :rejected],
    # Guardrails
    [:cyclium, :guardrail, :triggered],
    # Finding sweep
    [:cyclium, :finding_sweep, :completed],
    [:cyclium, :finding_sweep, :failed],
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
    # Conversations
    [:cyclium, :conversation, :started],
    [:cyclium, :conversation, :claimed],
    [:cyclium, :conversation, :resolved],
    [:cyclium, :conversation, :abandoned],
    [:cyclium, :conversation, :timed_out],
    [:cyclium, :conversation, :awaiting_participant]
  ]

  @doc "Returns the list of all Cyclium telemetry event names."
  @spec events() :: [list(atom())]
  def events, do: @events

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
  def handle_event(event, measurements, metadata, %{log_level: level}) do
    require Logger
    Logger.log(level, "[Cyclium] #{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
  end
end

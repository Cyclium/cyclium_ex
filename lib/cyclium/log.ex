defmodule Cyclium.Log do
  @moduledoc """
  Structured logging helpers for Cyclium.

  Sets process-level Logger metadata with `cyclium_`-prefixed keys so
  observability platforms (Datadog, Splunk, etc.) can parse structured fields
  from all subsequent log messages in that process.

  ## Usage

      # At process entry points:
      Cyclium.Log.set_context(cyclium_actor_id: actor_id)

      # Metadata persists for all Logger calls in the process.
  """

  require Logger

  @context_keys [
    :cyclium_actor_id,
    :cyclium_episode_id,
    :cyclium_expectation_id,
    :cyclium_workflow_id,
    :cyclium_instance_id,
    :cyclium_step_id,
    :cyclium_domain
  ]

  @doc """
  Sets Logger metadata for the current process context.
  Only `cyclium_`-prefixed keys are accepted.
  """
  def set_context(fields) when is_list(fields) do
    metadata = Keyword.take(fields, @context_keys)
    Logger.metadata(metadata)
  end
end

defmodule Cyclium.Telemetry do
  @moduledoc """
  Telemetry integration for Cyclium.

  ## Events

  ### Output events

      [:cyclium, :output, :delivered]
        metadata: %{type, dedupe_key, ref}

      [:cyclium, :output, :failed]
        metadata: %{type, dedupe_key, reason}

      [:cyclium, :output, :deduplicated]
        metadata: %{type, dedupe_key}

  ### Finding events

      [:cyclium, :finding, :raised]
        metadata: %{finding_key, actor_id, class}

      [:cyclium, :finding, :cleared]
        metadata: %{finding_key, actor_id, class}

  ### Episode events

      [:cyclium, :episode, :completed]
        metadata: %{episode_id, actor_id, output_count, finding_count}

      [:cyclium, :episode, :failed]
        metadata: %{episode_id, actor_id, error_class}

      [:cyclium, :episode, :dropped]
        metadata: %{actor_id, expectation_id}

  ## Usage

      # Attach a simple logger for development
      Cyclium.Telemetry.attach_default_logger()

      # Or attach your own handler to specific events
      :telemetry.attach("my-handler", [:cyclium, :output, :delivered], &MyHandler.handle/4, %{})
  """

  @events [
    [:cyclium, :output, :delivered],
    [:cyclium, :output, :failed],
    [:cyclium, :output, :deduplicated],
    [:cyclium, :finding, :raised],
    [:cyclium, :finding, :cleared],
    [:cyclium, :episode, :completed],
    [:cyclium, :episode, :failed],
    [:cyclium, :episode, :dropped]
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

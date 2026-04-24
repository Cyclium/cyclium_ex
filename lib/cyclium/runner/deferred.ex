defmodule Cyclium.Runner.Deferred do
  @moduledoc """
  Runner for trigger-only mode. Instead of executing episodes locally,
  writes a trigger request row for a full-mode node to pick up.
  """

  @behaviour Cyclium.Runner

  require Logger

  @impl true
  def enqueue(episode_id, opts \\ []) do
    case Cyclium.repo().get(Cyclium.Schemas.Episode, episode_id) do
      nil ->
        {:error, :episode_not_found}

      episode ->
        result =
          Cyclium.TriggerRequests.create(%{
            episode_id: episode_id,
            actor_id: episode.actor_id,
            expectation_id: episode.expectation_id,
            source_node: Cyclium.NodeIdentity.name(),
            source_stack: Cyclium.StackSlug.current(:all),
            opts: Map.new(opts)
          })

        case result do
          {:ok, trigger_request} ->
            Logger.info("Deferred episode to trigger request",
              cyclium_episode_id: episode_id,
              cyclium_trigger_request_id: trigger_request.id
            )

            {:ok, trigger_request}

          {:error, reason} ->
            Logger.warning("Failed to create trigger request: #{inspect(reason)}",
              cyclium_episode_id: episode_id
            )

            {:error, reason}
        end
    end
  end

  @impl true
  def recover_incomplete do
    # Full-mode node handles recovery via its poller
    :ok
  end

  @impl true
  def cancel(episode_id) do
    Cyclium.Episodes.update_status(episode_id, :canceled)
    :ok
  end
end

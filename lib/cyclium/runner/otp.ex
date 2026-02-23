defmodule Cyclium.Runner.OTP do
  @moduledoc """
  OTP-native episode runner. Uses DynamicSupervisor to run episodes as Tasks.
  No Oban required — the cyclium_episodes table is itself a durable work queue.
  """

  @behaviour Cyclium.Runner

  @impl true
  def enqueue(episode_id, opts \\ []) do
    DynamicSupervisor.start_child(
      Cyclium.EpisodeSupervisor,
      {Cyclium.EpisodeTask, episode_id: episode_id, opts: opts}
    )
  end

  @impl true
  def recover_incomplete do
    Cyclium.Episodes.list_by_status([:running, :blocked])
    |> Enum.each(fn ep ->
      if should_resume?(ep), do: enqueue(ep.id, resume: true)
    end)

    :ok
  end

  @impl true
  def cancel(episode_id) do
    Cyclium.Episodes.update_status(episode_id, :canceled)
    :ok
  end

  defp should_resume?(episode) do
    episode.status in [:running, :blocked] and
      episode.attempts < episode.max_attempts
  end
end

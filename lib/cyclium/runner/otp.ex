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
    # Only resume STALE :running episodes — never :blocked ones (those are
    # intentionally parked on an approval/external wait; resuming would replay
    # or re-block them), and never episodes another node may have started
    # moments ago. Staleness is gauged by step-journal recency, the same signal
    # Recovery.sweep/1 uses. The EpisodeTask claim gate still prevents two nodes
    # from running the same episode; for full cross-node coordination
    # (recovery_policy, shuffle), prefer `Cyclium.Recovery.sweep/1`.
    Cyclium.Episodes.list_stale_running(stale_after_ms())
    |> Enum.each(fn ep ->
      if ep.attempts < ep.max_attempts, do: enqueue(ep.id, resume: true)
    end)

    :ok
  end

  defp stale_after_ms, do: Application.get_env(:cyclium, :recover_incomplete_stale_ms, 120_000)

  @impl true
  def cancel(episode_id) do
    Cyclium.Episodes.update_status(episode_id, :canceled)
    :ok
  end
end

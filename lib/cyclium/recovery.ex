defmodule Cyclium.Recovery do
  @moduledoc """
  Recovers orphaned episodes after server restarts.

  After a deploy or crash, in-flight episodes are left as `:running` in the DB.
  `sweep/1` finds these stale episodes and either restarts or fails them based
  on the expectation's `recovery_policy`.

  ## Multi-node coordination

  All nodes in the cluster run the same sweep after boot. Coordination is
  DB-based via optimistic claims — `Episodes.claim_for_recovery/1` sets the
  episode's phase to `"recovering"` only if it's still `:running`. First node
  to claim wins; others silently skip.

  ## Usage

  Typically called from the host app's supervisor with a startup delay:

      {Task, fn ->
        Process.sleep(:timer.minutes(2))
        Cyclium.Recovery.sweep()
      end}

  ## Options

    * `:stale_after_ms` — consider an episode stale if no step journal activity
      for this long (default: 2 minutes)
    * `:resolve_policy` — `(episode -> :fail | :restart)` callback to determine
      recovery policy. Default: always `:fail`.
  """

  require Logger

  alias Cyclium.Episodes

  @default_stale_ms :timer.minutes(2)

  @doc """
  Sweep for orphaned `:running` episodes and recover them.

  Returns `{:ok, %{restarted: n, failed: n, skipped: n}}`.
  """
  def sweep(opts \\ []) do
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @default_stale_ms)
    resolve_policy = Keyword.get(opts, :resolve_policy, fn _ep -> :fail end)

    stale = Episodes.list_stale_running(stale_after_ms)

    Logger.info("[Cyclium.Recovery] Sweep found #{length(stale)} stale episode(s)")

    results =
      Enum.map(stale, fn episode ->
        case Episodes.claim_for_recovery(episode.id) do
          {:ok, claimed} ->
            recover_episode(claimed, resolve_policy)

          {:error, :already_claimed} ->
            :skipped
        end
      end)

    counts = %{
      restarted: Enum.count(results, &(&1 == :restarted)),
      failed: Enum.count(results, &(&1 == :failed)),
      skipped: Enum.count(results, &(&1 == :skipped))
    }

    :telemetry.execute(
      [:cyclium, :recovery, :sweep],
      counts,
      %{stale_after_ms: stale_after_ms}
    )

    Logger.info("[Cyclium.Recovery] Sweep complete: #{inspect(counts)}")

    {:ok, counts}
  end

  defp recover_episode(episode, resolve_policy) do
    policy = resolve_policy.(episode)

    case policy do
      :restart ->
        Logger.info(
          "[Cyclium.Recovery] Restarting episode #{episode.id} " <>
            "(#{episode.actor_id}/#{episode.expectation_id})"
        )

        # Reset status to :running (clear the "recovering" phase)
        Episodes.update_status(episode.id, :running, phase: nil)
        runner().enqueue(episode.id)
        :restarted

      :fail ->
        Logger.info(
          "[Cyclium.Recovery] Failing orphaned episode #{episode.id} " <>
            "(#{episode.actor_id}/#{episode.expectation_id})"
        )

        Episodes.update_status(episode.id, :failed,
          error_class: "orphaned",
          error_detail: %{"reason" => "Server restart recovery — policy: fail"}
        )

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed
        })

        :failed
    end
  end

  defp runner do
    Application.get_env(:cyclium, :runner, Cyclium.Runner.OTP)
  end
end

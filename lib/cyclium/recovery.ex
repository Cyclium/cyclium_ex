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
    * `:actor_registry` — map of `%{"actor_id" => ActorModule}`. Recovery looks
      up `recovery_policy` from the actor module's compiled expectations. This is
      the recommended option — pass your actor modules and Cyclium handles the rest.
    * `:resolve_policy` — `(episode -> :fail | :restart)` callback for custom
      policy resolution. Overrides `:actor_registry` if both are provided.

  ## Examples

      # Recommended: pass an actor registry map
      Cyclium.Recovery.sweep(
        actor_registry: %{
          "project_health_actor" => MyApp.Actors.ProjectHealthActor
        }
      )

      # Custom: pass a resolve_policy function
      Cyclium.Recovery.sweep(
        resolve_policy: fn _episode -> :restart end
      )
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

    resolve_policy =
      cond do
        Keyword.has_key?(opts, :resolve_policy) ->
          Keyword.fetch!(opts, :resolve_policy)

        Keyword.has_key?(opts, :actor_registry) ->
          registry = Keyword.fetch!(opts, :actor_registry)
          &resolve_policy_from_registry(&1, registry)

        true ->
          fn _ep -> :fail end
      end

    stale = Episodes.list_stale_running(stale_after_ms)

    Logger.info("[Cyclium.Recovery] Sweep found #{length(stale)} stale episode(s)")

    results =
      Enum.map(stale, fn episode ->
        case claim_episode(episode) do
          {:ok, claimed} ->
            recover_episode(claimed, resolve_policy)

          {:error, _} ->
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

  defp claim_episode(episode) do
    if Cyclium.WorkClaims.configured?() and episode.dedupe_key do
      case Cyclium.WorkClaims.gate_acquire(episode.dedupe_key, node_name(), work_type: "recovery") do
        {:ok, _claim} -> Episodes.claim_for_recovery(episode.id)
        {:error, :busy} -> {:error, :busy}
      end
    else
      Episodes.claim_for_recovery(episode.id)
    end
  end

  defp node_name, do: node() |> to_string()

  defp resolve_policy_from_registry(episode, registry) do
    with actor_module when not is_nil(actor_module) <- Map.get(registry, episode.actor_id),
         true <- function_exported?(actor_module, :__cyclium_expectations__, 0),
         raw_expectations <- actor_module.__cyclium_expectations__(),
         expectation_id <- String.to_existing_atom(episode.expectation_id),
         {_id, opts} <- List.keyfind(raw_expectations, expectation_id, 0) do
      Keyword.get(opts, :recovery_policy, :fail)
    else
      _ -> :fail
    end
  rescue
    _ -> :fail
  end

  defp runner do
    Application.get_env(:cyclium, :runner, Cyclium.Runner.OTP)
  end
end

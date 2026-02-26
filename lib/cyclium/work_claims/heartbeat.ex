defmodule Cyclium.WorkClaims.Heartbeat do
  @moduledoc """
  Periodically renews a work claim lease while an episode is executing.

  Started by `EpisodeTask` after a successful claim acquisition, and
  stopped when the episode completes or fails. The renewal interval
  defaults to lease_seconds / 3 to ensure the lease stays alive with
  margin for transient delays.

  ## Crash resilience

  The heartbeat is linked to the calling process (EpisodeTask). If the
  heartbeat crashes, the EpisodeTask receives an EXIT and restarts it.
  If the EpisodeTask crashes, the heartbeat dies with it. This ensures
  the heartbeat lifecycle is always tied to the episode execution.

  ## Options

    * `:dedupe_key` — the claimed dedupe key (required)
    * `:owner_node` — the node that holds the claim (required)
    * `:lease_seconds` — lease duration for renewals (required)
    * `:interval_ms` — renewal interval in ms (default: lease_seconds * 1000 / 3)
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def stop(nil), do: :ok

  @impl true
  def init(opts) do
    dedupe_key = Keyword.fetch!(opts, :dedupe_key)
    owner_node = Keyword.fetch!(opts, :owner_node)
    lease_seconds = Keyword.fetch!(opts, :lease_seconds)
    interval_ms = Keyword.get(opts, :interval_ms, div(lease_seconds * 1000, 3))

    state = %{
      dedupe_key: dedupe_key,
      owner_node: owner_node,
      lease_seconds: lease_seconds,
      interval_ms: interval_ms,
      consecutive_failures: 0
    }

    schedule_renew(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:renew, state) do
    case Cyclium.WorkClaims.gate_renew(state.dedupe_key, state.owner_node, state.lease_seconds) do
      :ok ->
        schedule_renew(state.interval_ms)
        {:noreply, %{state | consecutive_failures: 0}}

      {:error, :not_owner} ->
        Logger.warning(
          "[Cyclium.Heartbeat] Lost claim ownership for #{state.dedupe_key} — stopping heartbeat"
        )

        {:stop, :normal, state}
    end
  end

  defp schedule_renew(interval_ms) do
    Process.send_after(self(), :renew, interval_ms)
  end
end

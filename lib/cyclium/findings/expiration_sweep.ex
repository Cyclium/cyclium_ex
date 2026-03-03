defmodule Cyclium.Findings.ExpirationSweep do
  @moduledoc """
  Periodic GenServer that clears expired findings.

  Queries active findings where `expires_at <= now` and sets their status
  to `:cleared` in batches. Emits `[:cyclium, :finding, :expired]` telemetry.

  ## Configuration

      # In your application config:
      config :cyclium, :finding_expiration_sweep, true
      config :cyclium, :finding_expiration_interval_ms, :timer.minutes(5)
      config :cyclium, :finding_expiration_batch_size, 100

  ## Supervisor

  Added automatically by `Cyclium.Supervisor` when enabled.
  """

  use GenServer

  require Logger

  import Ecto.Query
  alias Cyclium.Schemas.Finding

  @default_interval_ms :timer.minutes(5)
  @default_batch_size 100

  @sweep_dedupe_key "cyclium:sweep:expiration"
  @sweep_lease_seconds 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    schedule_sweep(interval)
    {:ok, %{interval: interval, batch_size: batch_size()}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Cyclium.WorkClaims.gate_acquire(@sweep_dedupe_key, node_name(),
           lease_seconds: @sweep_lease_seconds,
           work_type: "sweep"
         ) do
      {:error, :busy} ->
        :skipped

      _acquired ->
        try do
          count = sweep_expired(state.batch_size)

          if count > 0 do
            Logger.info("Expiration sweep cleared #{count} expired finding(s)")
          end

          Cyclium.Findings.Escalation.sweep()

          Cyclium.WorkClaims.gate_complete(@sweep_dedupe_key, node_name())
        rescue
          e ->
            Cyclium.WorkClaims.gate_fail(@sweep_dedupe_key, node_name(), %{
              "reason" => "exception",
              "message" => Exception.message(e)
            })

            Logger.error("Expiration sweep failed: #{Exception.message(e)}")
        end
    end

    schedule_sweep(state.interval)
    {:noreply, state}
  end

  @doc """
  Run the expiration sweep manually. Returns the count of cleared findings.
  """
  def sweep_expired(batch_size \\ batch_size()) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Select IDs first — update_all doesn't support limit
    ids =
      from(f in Finding,
        where: f.status == :active,
        where: not is_nil(f.expires_at),
        where: f.expires_at <= ^now,
        limit: ^batch_size,
        select: f.id
      )
      |> repo().all()

    count =
      case ids do
        [] ->
          0

        ids ->
          # Archive any already-cleared findings with the same finding_keys
          # to avoid unique constraint violation on (finding_key, status)
          finding_keys =
            from(f in Finding, where: f.id in ^ids, select: f.finding_key)
            |> repo().all()

          from(f in Finding,
            where: f.finding_key in ^finding_keys,
            where: f.status == :cleared
          )
          |> repo().update_all(set: [status: :superseded, archived_at: now, updated_at: now])

          {n, _} =
            from(f in Finding, where: f.id in ^ids)
            |> repo().update_all(set: [status: :cleared, cleared_at: now, updated_at: now])

          n
      end

    if count > 0 do
      :telemetry.execute(
        [:cyclium, :finding, :expired],
        %{count: count},
        %{}
      )
    end

    count
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp interval_ms do
    Application.get_env(:cyclium, :finding_expiration_interval_ms, @default_interval_ms)
  end

  defp batch_size do
    Application.get_env(:cyclium, :finding_expiration_batch_size, @default_batch_size)
  end

  defp node_name, do: node() |> to_string()

  defp repo, do: Cyclium.repo()
end

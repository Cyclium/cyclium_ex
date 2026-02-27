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
    count = sweep_expired(state.batch_size)

    if count > 0 do
      Logger.info("Expiration sweep cleared #{count} expired finding(s)")
    end

    # Run escalation sweep after expiration
    Cyclium.Findings.Escalation.sweep()

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

  defp repo, do: Cyclium.repo()
end

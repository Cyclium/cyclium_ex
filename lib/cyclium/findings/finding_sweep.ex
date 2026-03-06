defmodule Cyclium.Findings.FindingSweep do
  @moduledoc """
  Periodic GenServer that maintains finding health: clears expired findings
  and escalates active findings based on time-based severity rules.

  ## Configuration

      config :cyclium, :finding_sweep, true
      config :cyclium, :finding_sweep_interval_ms, :timer.minutes(5)
      config :cyclium, :finding_sweep_batch_size, 100

  ## Supervisor

  Added automatically by `Cyclium.Supervisor` when enabled.
  """

  use GenServer

  require Logger

  import Ecto.Query
  alias Cyclium.Findings.Escalation
  alias Cyclium.Schemas.Finding

  @default_interval_ms :timer.minutes(5)
  @default_batch_size 100

  @sweep_dedupe_key "cyclium:sweep:findings"
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
        start = System.monotonic_time()

        try do
          expired_count = sweep_expired(state.batch_size)

          if expired_count > 0 do
            Logger.info("Finding sweep cleared #{expired_count} expired finding(s)")
          end

          escalated_count = sweep_escalations()

          if escalated_count > 0 do
            Logger.info("Finding sweep escalated #{escalated_count} finding(s)")
          end

          duration_ms =
            System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

          :telemetry.execute(
            [:cyclium, :finding_sweep, :completed],
            %{
              duration_ms: duration_ms,
              expired_count: expired_count,
              escalated_count: escalated_count
            },
            %{node: node_name()}
          )

          Cyclium.WorkClaims.gate_complete(@sweep_dedupe_key, node_name())
        rescue
          e ->
            duration_ms =
              System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

            :telemetry.execute(
              [:cyclium, :finding_sweep, :failed],
              %{duration_ms: duration_ms},
              %{node: node_name(), reason: Exception.message(e)}
            )

            Cyclium.WorkClaims.gate_fail(@sweep_dedupe_key, node_name(), %{
              "reason" => "exception",
              "message" => Exception.message(e)
            })

            Logger.error("Finding sweep failed: #{Exception.message(e)}")
        end
    end

    schedule_sweep(state.interval)
    {:noreply, state}
  end

  @doc """
  Clear expired findings. Returns the count of cleared findings.
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
          # to avoid unique constraint violation on (finding_key, status).
          # Note: superseded rows are excluded from the unique index (V13)
          # so multiple superseded rows per finding_key are allowed.
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

  @doc """
  Escalate active findings based on configured time-based rules.
  Returns the count of escalated findings.
  """
  def sweep_escalations do
    pairs = Cyclium.Findings.Config.escalation_pairs()

    if pairs == [] do
      0
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Enum.reduce(pairs, 0, fn {actor_id, exp_id, rules_by_class}, count ->
        classes = Map.keys(rules_by_class)
        all_rules = rules_by_class |> Map.values() |> List.flatten()

        # Only load findings old enough to potentially match the earliest rule
        min_after = all_rules |> Enum.map(& &1.after_minutes) |> Enum.min()
        cutoff = DateTime.add(now, -min_after, :minute)

        # Skip findings already at the highest severity any rule can escalate to
        max_target =
          all_rules
          |> Enum.map(& &1.escalate_to)
          |> Enum.max_by(&Escalation.severity_index/1)

        findings =
          repo().all(
            from(f in Finding,
              where: f.status == :active,
              where: f.actor_id == ^actor_id,
              where: f.expectation_id == ^exp_id,
              where: f.class in ^classes,
              where: f.raised_at <= ^cutoff,
              where: f.severity != ^max_target
            )
          )

        count + escalate_findings(findings, rules_by_class, now)
      end)
    end
  end

  defp escalate_findings(findings, rules_by_class, now) do
    Enum.reduce(findings, 0, fn finding, count ->
      rules = Map.get(rules_by_class, finding.class, [])

      case Escalation.check(finding, rules) do
        {:escalate, new_severity} ->
          case finding
               |> Finding.changeset(%{severity: new_severity, updated_at: now})
               |> repo().update() do
            {:ok, _} ->
              :telemetry.execute(
                [:cyclium, :finding, :escalated],
                %{count: 1},
                %{
                  finding_key: finding.finding_key,
                  class: finding.class,
                  from: finding.severity,
                  to: new_severity
                }
              )

              count + 1

            {:error, _} ->
              count
          end

        :no_change ->
          count
      end
    end)
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp interval_ms do
    Application.get_env(:cyclium, :finding_sweep_interval_ms, @default_interval_ms)
  end

  defp batch_size do
    Application.get_env(:cyclium, :finding_sweep_batch_size, @default_batch_size)
  end

  defp node_name, do: Cyclium.NodeIdentity.name()

  defp repo, do: Cyclium.repo()
end

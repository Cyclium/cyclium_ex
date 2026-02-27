defmodule Cyclium.Findings.Escalation do
  @moduledoc """
  Time-based severity escalation for active findings.

  Evaluates escalation rules against active findings and bumps severity
  when findings have been active longer than the configured thresholds.

  ## Rules format

  Rules are configured per finding class, declared on the expectation:

      expectation :check_vendor,
        trigger: {:event, "vendor.updated"},
        escalation_rules: %{
          "vendor_delay" => [
            %{after_minutes: 60, escalate_to: :high},
            %{after_minutes: 1440, escalate_to: :critical}
          ]
        }

  Falls back to application config for backwards compatibility:

      config :cyclium, :escalation_rules, %{...}

  Rules are evaluated from longest `after_minutes` first. The first matching
  rule (where the finding has been active for at least that duration) wins.

  ## Usage

  Typically run as part of the `ExpirationSweep` cycle, or manually:

      Cyclium.Findings.Escalation.sweep()
  """

  require Logger

  import Ecto.Query
  alias Cyclium.Schemas.Finding

  @severity_order [:low, :medium, :high, :critical]

  @doc """
  Check if a single finding should be escalated based on rules.

  Returns `{:escalate, new_severity}` or `:no_change`.
  """
  def check(finding, rules) when is_list(rules) do
    age_minutes = age_in_minutes(finding)
    current_idx = severity_index(finding.severity)

    # Sort rules by after_minutes descending — longest match first
    sorted = Enum.sort_by(rules, & &1.after_minutes, :desc)

    case Enum.find(sorted, fn rule ->
           target_idx = severity_index(rule.escalate_to)
           age_minutes >= rule.after_minutes and target_idx > current_idx
         end) do
      nil -> :no_change
      rule -> {:escalate, rule.escalate_to}
    end
  end

  @doc """
  Sweep all active findings and escalate those matching configured rules.

  Returns the count of escalated findings.
  """
  def sweep(rules_by_class \\ Cyclium.Findings.Config.all_escalation_rules()) do
    if map_size(rules_by_class) == 0 do
      0
    else
      classes = Map.keys(rules_by_class)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      findings =
        repo().all(
          from(f in Finding,
            where: f.status == :active,
            where: f.class in ^classes
          )
        )

      escalated =
        Enum.reduce(findings, 0, fn finding, count ->
          rules = Map.get(rules_by_class, finding.class, [])

          case check(finding, rules) do
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

      if escalated > 0 do
        Logger.info("Escalation sweep escalated #{escalated} finding(s)")
      end

      escalated
    end
  end

  defp age_in_minutes(%{raised_at: nil}), do: 0

  defp age_in_minutes(%{raised_at: raised_at}) do
    DateTime.diff(DateTime.utc_now(), raised_at, :second) / 60
  end

  defp severity_index(severity) do
    Enum.find_index(@severity_order, &(&1 == severity)) || 0
  end

  defp repo, do: Cyclium.repo()
end

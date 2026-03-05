defmodule Cyclium.Findings.Escalation do
  @moduledoc """
  Time-based severity escalation rules for active findings.

  Evaluates escalation rules against a finding and determines whether it
  should be bumped to a higher severity based on how long it has been active.

  Rules are evaluated from longest `after_minutes` first. The first matching
  rule (where the finding has been active for at least that duration) wins.

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
  """

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

  defp age_in_minutes(%{raised_at: nil}), do: 0

  defp age_in_minutes(%{raised_at: raised_at}) do
    DateTime.diff(DateTime.utc_now(), raised_at, :second) / 60
  end

  defp severity_index(severity) do
    Enum.find_index(@severity_order, &(&1 == severity)) || 0
  end
end

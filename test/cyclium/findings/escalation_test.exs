defmodule Cyclium.Findings.EscalationTest do
  use ExUnit.Case, async: true

  alias Cyclium.Findings.Escalation

  describe "check/2" do
    test "escalates when age exceeds threshold" do
      finding = %{
        severity: :low,
        raised_at: DateTime.utc_now() |> DateTime.add(-120, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high}
      ]

      assert {:escalate, :high} = Escalation.check(finding, rules)
    end

    test "no change when age is below threshold" do
      finding = %{
        severity: :low,
        raised_at: DateTime.utc_now() |> DateTime.add(-30, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high}
      ]

      assert :no_change = Escalation.check(finding, rules)
    end

    test "no change when already at target severity" do
      finding = %{
        severity: :high,
        raised_at: DateTime.utc_now() |> DateTime.add(-120, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high}
      ]

      assert :no_change = Escalation.check(finding, rules)
    end

    test "no change when already above target severity" do
      finding = %{
        severity: :critical,
        raised_at: DateTime.utc_now() |> DateTime.add(-120, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high}
      ]

      assert :no_change = Escalation.check(finding, rules)
    end

    test "picks longest matching rule" do
      finding = %{
        severity: :low,
        raised_at: DateTime.utc_now() |> DateTime.add(-1500, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high},
        %{after_minutes: 1440, escalate_to: :critical}
      ]

      assert {:escalate, :critical} = Escalation.check(finding, rules)
    end

    test "falls back to shorter rule when longer not met" do
      finding = %{
        severity: :low,
        raised_at: DateTime.utc_now() |> DateTime.add(-120, :minute)
      }

      rules = [
        %{after_minutes: 60, escalate_to: :high},
        %{after_minutes: 1440, escalate_to: :critical}
      ]

      assert {:escalate, :high} = Escalation.check(finding, rules)
    end

    test "handles empty rules" do
      finding = %{
        severity: :low,
        raised_at: DateTime.utc_now() |> DateTime.add(-120, :minute)
      }

      assert :no_change = Escalation.check(finding, [])
    end

    test "handles nil raised_at" do
      finding = %{severity: :low, raised_at: nil}

      rules = [%{after_minutes: 60, escalate_to: :high}]

      assert :no_change = Escalation.check(finding, rules)
    end
  end

  describe "telemetry" do
    test "escalated event is declared" do
      events = Cyclium.Telemetry.events()
      assert [:cyclium, :finding, :escalated] in events
    end
  end
end

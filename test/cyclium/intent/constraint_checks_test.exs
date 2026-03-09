defmodule Cyclium.Intent.ConstraintChecksTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{ConstraintChecks, ToolSignature}

  defp sig(constraints) do
    %ToolSignature{name: "t", version: 1, side_effect: :read, constraints: constraints}
  end

  describe "check/2" do
    test "passes when no constraints" do
      assert :ok = ConstraintChecks.check(%{"limit" => 100}, sig(%{}))
    end

    test "max_rows passes when within limit" do
      assert :ok = ConstraintChecks.check(%{"limit" => 50}, sig(%{"max_rows" => 100}))
    end

    test "max_rows passes when no limit arg present" do
      assert :ok = ConstraintChecks.check(%{}, sig(%{"max_rows" => 100}))
    end

    test "max_rows denies when exceeded" do
      assert {:deny, msg} = ConstraintChecks.check(%{"limit" => 200}, sig(%{"max_rows" => 100}))
      assert msg =~ "max_rows constraint exceeded"
    end

    test "max_rows also checks max_rows key in args" do
      assert {:deny, _} = ConstraintChecks.check(%{"max_rows" => 200}, sig(%{"max_rows" => 100}))
    end

    test "max_window_minutes passes within limit" do
      assert :ok =
               ConstraintChecks.check(
                 %{"window_minutes" => 30},
                 sig(%{"max_window_minutes" => 60})
               )
    end

    test "max_window_minutes denies when exceeded" do
      assert {:deny, msg} =
               ConstraintChecks.check(
                 %{"window_minutes" => 120},
                 sig(%{"max_window_minutes" => 60})
               )

      assert msg =~ "max_window_minutes constraint exceeded"
    end

    test "allowed_fields passes with all allowed" do
      assert :ok =
               ConstraintChecks.check(
                 %{"fields" => ["name", "email"]},
                 sig(%{"allowed_fields" => ["name", "email", "phone"]})
               )
    end

    test "allowed_fields denies disallowed fields" do
      assert {:deny, msg} =
               ConstraintChecks.check(
                 %{"fields" => ["name", "ssn"]},
                 sig(%{"allowed_fields" => ["name", "email"]})
               )

      assert msg =~ "disallowed fields"
      assert msg =~ "ssn"
    end

    test "allowed_fields passes when no fields arg" do
      assert :ok =
               ConstraintChecks.check(%{}, sig(%{"allowed_fields" => ["name"]}))
    end

    test "unknown constraint keys are ignored" do
      assert :ok = ConstraintChecks.check(%{"foo" => "bar"}, sig(%{"some_future_thing" => 99}))
    end
  end
end

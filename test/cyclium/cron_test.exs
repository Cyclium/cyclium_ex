defmodule Cyclium.CronTest do
  use ExUnit.Case, async: true

  alias Cyclium.Cron

  describe "parse/1" do
    test "parses a basic daily spec" do
      assert {:ok, cron} = Cron.parse("0 5 * * *")
      assert cron.minute == MapSet.new([0])
      assert cron.hour == MapSet.new([5])
      assert cron.month == MapSet.new(1..12)
      assert cron.dom == MapSet.new(1..31)
      assert cron.dow == MapSet.new(0..6)
      refute cron.dom_restricted
      refute cron.dow_restricted
    end

    test "parses steps, ranges, and lists" do
      assert {:ok, c} = Cron.parse("*/15 * * * *")
      assert c.minute == MapSet.new([0, 15, 30, 45])

      assert {:ok, c} = Cron.parse("0 9-17 * * *")
      assert c.hour == MapSet.new(9..17)

      assert {:ok, c} = Cron.parse("0 0-23/6 * * *")
      assert c.hour == MapSet.new([0, 6, 12, 18])

      assert {:ok, c} = Cron.parse("0 9,12,17 * * *")
      assert c.hour == MapSet.new([9, 12, 17])
    end

    test "day-of-week 7 normalizes to 0 (Sunday)" do
      assert {:ok, c} = Cron.parse("0 0 * * 7")
      assert c.dow == MapSet.new([0])
      assert c.dow_restricted
    end

    test "tracks dom/dow restriction flags" do
      assert {:ok, c} = Cron.parse("0 0 13 * 5")
      assert c.dom_restricted
      assert c.dow_restricted
    end

    test "expands macros" do
      assert Cron.parse("@daily") == Cron.parse("0 0 * * *")
      assert Cron.parse("@midnight") == Cron.parse("0 0 * * *")
      assert Cron.parse("@hourly") == Cron.parse("0 * * * *")
      assert Cron.parse("@weekly") == Cron.parse("0 0 * * 0")
      assert Cron.parse("@monthly") == Cron.parse("0 0 1 * *")
      assert Cron.parse("@yearly") == Cron.parse("0 0 1 1 *")
      assert Cron.parse("@annually") == Cron.parse("0 0 1 1 *")
    end

    test "trims surrounding whitespace" do
      assert Cron.parse("  0 5 * * *  ") == Cron.parse("0 5 * * *")
    end

    test "rejects malformed specs" do
      assert {:error, {:expected_5_fields, 4}} = Cron.parse("0 5 * *")
      assert {:error, {:expected_5_fields, 6}} = Cron.parse("0 5 * * * *")
      assert {:error, _} = Cron.parse("x 5 * * *")
      assert {:error, {:out_of_range, _, :minute}} = Cron.parse("60 * * * *")
      assert {:error, {:out_of_range, _, :hour}} = Cron.parse("0 24 * * *")
      assert {:error, {:out_of_range, _, :dow}} = Cron.parse("0 0 * * 8")
      assert {:error, {:reversed_range, _}} = Cron.parse("0 17-9 * * *")
      assert {:error, {:invalid_step, _}} = Cron.parse("*/0 * * * *")
      assert {:error, {:not_a_string, _}} = Cron.parse(:not_a_string)
    end
  end

  describe "parse!/1" do
    test "returns the struct on success" do
      assert %Cron{} = Cron.parse!("0 5 * * *")
    end

    test "raises with the offending spec on failure" do
      assert_raise ArgumentError, ~r/invalid cron expression "nope"/, fn ->
        Cron.parse!("nope")
      end
    end
  end

  describe "next/2" do
    test "returns today's occurrence when before it" do
      c = Cron.parse!("0 5 * * *")
      assert Cron.next(c, ~U[2026-06-05 04:59:30Z]) == ~U[2026-06-05 05:00:00Z]
    end

    test "is strictly after the given time (rolls to next day on the tick)" do
      c = Cron.parse!("0 5 * * *")
      assert Cron.next(c, ~U[2026-06-05 05:00:00Z]) == ~U[2026-06-06 05:00:00Z]
    end

    test "steps to the next interval slot" do
      c = Cron.parse!("*/15 * * * *")
      assert Cron.next(c, ~U[2026-06-05 10:07:00Z]) == ~U[2026-06-05 10:15:00Z]
      assert Cron.next(c, ~U[2026-06-05 10:45:00Z]) == ~U[2026-06-05 11:00:00Z]
    end

    test "rolls across month boundaries" do
      c = Cron.parse!("0 0 1 * *")
      assert Cron.next(c, ~U[2026-06-15 12:00:00Z]) == ~U[2026-07-01 00:00:00Z]
    end

    test "honors day-of-week (Monday 09:00)" do
      c = Cron.parse!("0 9 * * 1")
      # 2026-06-05 is a Friday → next Monday is 2026-06-08.
      assert Cron.next(c, ~U[2026-06-05 12:00:00Z]) == ~U[2026-06-08 09:00:00Z]
    end

    test "dom and dow are OR'd when both restricted" do
      # Midnight on the 13th OR any Friday.
      c = Cron.parse!("0 0 13 * 5")
      # 2026-06-05 (Fri) already past midnight → next Friday 2026-06-12 ...
      assert Cron.next(c, ~U[2026-06-05 12:00:00Z]) == ~U[2026-06-12 00:00:00Z]
      # ... but from the 12th midnight, the 13th (Sat) matches via dom.
      assert Cron.next(c, ~U[2026-06-12 00:00:00Z]) == ~U[2026-06-13 00:00:00Z]
    end

    test "finds a sparse occurrence within the multi-year cap (Feb 29)" do
      c = Cron.parse!("0 0 29 2 *")
      assert Cron.next(c, ~U[2026-06-01 00:00:00Z]) == ~U[2028-02-29 00:00:00Z]
    end

    test "raises for an impossible date spec" do
      c = Cron.parse!("0 0 30 2 *")

      assert_raise ArgumentError, ~r/no reachable occurrence/, fn ->
        Cron.next(c, ~U[2026-06-01 00:00:00Z])
      end
    end
  end

  describe "match?/2" do
    test "matches on all fields" do
      c = Cron.parse!("0 5 * * *")
      assert Cron.match?(c, ~U[2026-06-05 05:00:00Z])
      refute Cron.match?(c, ~U[2026-06-05 05:01:00Z])
      refute Cron.match?(c, ~U[2026-06-05 06:00:00Z])
    end
  end
end

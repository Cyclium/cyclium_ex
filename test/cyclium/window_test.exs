defmodule Cyclium.WindowTest do
  use ExUnit.Case

  alias Cyclium.Window

  describe "bucket(:h4)" do
    test "aligns to 4-hour slots" do
      assert Window.bucket(:h4, ~U[2026-02-23 00:00:00Z]) == "2026-02-23T00"
      assert Window.bucket(:h4, ~U[2026-02-23 03:59:59Z]) == "2026-02-23T00"
      assert Window.bucket(:h4, ~U[2026-02-23 04:00:00Z]) == "2026-02-23T04"
      assert Window.bucket(:h4, ~U[2026-02-23 13:45:00Z]) == "2026-02-23T12"
      assert Window.bucket(:h4, ~U[2026-02-23 23:59:59Z]) == "2026-02-23T20"
    end

    test "same slot within window, different across boundary" do
      assert Window.bucket(:h4, ~U[2026-02-23 08:00:00Z]) ==
               Window.bucket(:h4, ~U[2026-02-23 11:59:59Z])

      refute Window.bucket(:h4, ~U[2026-02-23 11:59:59Z]) ==
               Window.bucket(:h4, ~U[2026-02-23 12:00:00Z])
    end
  end

  describe "bucket(:h24)" do
    test "returns ISO date string" do
      assert Window.bucket(:h24, ~U[2026-02-23 00:00:00Z]) == "2026-02-23"
      assert Window.bucket(:h24, ~U[2026-02-23 23:59:59Z]) == "2026-02-23"
    end

    test "changes at midnight" do
      refute Window.bucket(:h24, ~U[2026-02-23 23:59:59Z]) ==
               Window.bucket(:h24, ~U[2026-02-24 00:00:00Z])
    end
  end

  describe "bucket(:h48)" do
    test "pairs consecutive days into same bucket" do
      # Day 1 and Day 2 → same bucket
      assert Window.bucket(:h48, ~U[2026-01-01 12:00:00Z]) ==
               Window.bucket(:h48, ~U[2026-01-02 12:00:00Z])
    end

    test "different pairs get different buckets" do
      # Day 2 (pair 1) vs Day 3 (pair 2)
      refute Window.bucket(:h48, ~U[2026-01-02 12:00:00Z]) ==
               Window.bucket(:h48, ~U[2026-01-03 12:00:00Z])
    end

    test "returns year-d format" do
      assert Window.bucket(:h48, ~U[2026-01-01 00:00:00Z]) =~ ~r/^\d{4}-d\d{3}$/
    end
  end

  describe "bucket(:w1)" do
    test "Monday and Sunday of same week share bucket" do
      # Feb 23, 2026 is a Monday
      monday = ~U[2026-02-23 00:00:00Z]
      sunday = ~U[2026-03-01 23:59:59Z]
      assert Window.bucket(:w1, monday) == Window.bucket(:w1, sunday)
    end

    test "consecutive weeks differ" do
      # Sunday of W08 vs Monday of W09
      refute Window.bucket(:w1, ~U[2026-02-22 23:59:59Z]) ==
               Window.bucket(:w1, ~U[2026-02-23 00:00:00Z])
    end

    test "returns year-W format" do
      assert Window.bucket(:w1, ~U[2026-02-23 12:00:00Z]) =~ ~r/^\d{4}-W\d{2}$/
    end

    test "year-crossing ISO weeks" do
      # Dec 31, 2025 is a Wednesday — ISO week 1 of 2026
      assert "2026-W01" == Window.bucket(:w1, ~U[2025-12-31 12:00:00Z])
    end
  end
end

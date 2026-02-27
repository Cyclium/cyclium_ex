defmodule Cyclium.SamplingTest do
  use ExUnit.Case, async: true

  alias Cyclium.Expectation

  # Test the sampled_out? logic via the actor module's internal function.
  # Since sampled_out? is private, we test the observable behavior through
  # the Expectation struct and :rand seeding.

  describe "sample_rate field" do
    test "expectation defaults to nil sample_rate" do
      exp = %Expectation{}
      assert exp.sample_rate == nil
    end

    test "sample_rate can be set" do
      exp = %Expectation{sample_rate: 0.5}
      assert exp.sample_rate == 0.5
    end
  end

  describe "sampling behavior" do
    # We test the sampling logic directly since the private function
    # matches the pattern used in actor.ex

    test "nil sample_rate never samples out" do
      refute sampled_out?(%{sample_rate: nil})
    end

    test "sample_rate >= 1.0 never samples out" do
      refute sampled_out?(%{sample_rate: 1.0})
      refute sampled_out?(%{sample_rate: 1.5})
    end

    test "sample_rate <= 0.0 always samples out" do
      assert sampled_out?(%{sample_rate: 0.0})
      assert sampled_out?(%{sample_rate: -0.1})
    end

    test "sample_rate 0.5 samples roughly half with seeded rand" do
      :rand.seed(:exsss, {100, 200, 300})

      results =
        for _ <- 1..1000 do
          sampled_out?(%{sample_rate: 0.5})
        end

      out_count = Enum.count(results, & &1)
      # With 1000 samples at 0.5, expect ~500 sampled out (allow wide margin)
      assert out_count > 350 and out_count < 650,
             "Expected ~500 sampled out, got #{out_count}"
    end

    test "sample_rate 0.1 samples out most episodes" do
      :rand.seed(:exsss, {100, 200, 300})

      results =
        for _ <- 1..1000 do
          sampled_out?(%{sample_rate: 0.1})
        end

      out_count = Enum.count(results, & &1)
      # With rate 0.1, ~90% should be sampled out
      assert out_count > 800, "Expected >800 sampled out, got #{out_count}"
    end
  end

  describe "telemetry event" do
    test "sampled_out event is declared" do
      events = Cyclium.Telemetry.events()
      assert [:cyclium, :episode, :sampled_out] in events
    end
  end

  # Mirror the private logic from actor.ex for direct testing
  defp sampled_out?(%{sample_rate: nil}), do: false
  defp sampled_out?(%{sample_rate: rate}) when rate >= 1.0, do: false
  defp sampled_out?(%{sample_rate: rate}) when rate <= 0.0, do: true
  defp sampled_out?(%{sample_rate: rate}), do: :rand.uniform() > rate
end

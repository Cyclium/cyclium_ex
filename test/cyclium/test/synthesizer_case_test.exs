defmodule Cyclium.Test.SynthesizerCaseTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.SynthesizerCase

  alias Cyclium.TestKit.SampleSynthesizer

  describe "assert_valid_synthesize/3" do
    test "passes for valid synthesizer" do
      prompt_ctx = %{system: "test", messages: []}
      episode_ctx = Cyclium.Test.StrategyCase.build_episode_ctx()

      result = assert_valid_synthesize(SampleSynthesizer, prompt_ctx, episode_ctx)
      assert {:ok, %{"response" => _}} = result
    end
  end

  describe "assert_valid_estimate_tokens/2" do
    test "passes for valid estimate" do
      prompt_ctx = %{system: "test"}
      result = assert_valid_estimate_tokens(SampleSynthesizer, prompt_ctx)
      assert result == 150
    end
  end

  describe "FakeSynthesizer" do
    setup do
      {:ok, _} = Cyclium.Test.FakeSynthesizer.start_link()

      on_exit(fn ->
        try do
          if pid = Process.whereis(Cyclium.Test.FakeSynthesizer), do: Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "returns default response" do
      assert {:ok, %{"response" => "mock"}} =
               Cyclium.Test.FakeSynthesizer.synthesize(%{}, %{})
    end

    test "returns configured response" do
      Cyclium.Test.FakeSynthesizer.set_response(%{"answer" => "42"})

      assert {:ok, %{"answer" => "42"}} =
               Cyclium.Test.FakeSynthesizer.synthesize(%{}, %{})
    end

    test "returns configured error" do
      Cyclium.Test.FakeSynthesizer.set_error(:rate_limited, %{retry_after: 60})

      assert {:error, :rate_limited, %{retry_after: 60}} =
               Cyclium.Test.FakeSynthesizer.synthesize(%{}, %{})
    end

    test "records calls" do
      prompt = %{system: "test"}
      ctx = %{episode_id: "ep-1"}

      Cyclium.Test.FakeSynthesizer.synthesize(prompt, ctx)
      Cyclium.Test.FakeSynthesizer.synthesize(%{system: "test2"}, ctx)

      calls = Cyclium.Test.FakeSynthesizer.calls()
      assert length(calls) == 2
      assert {%{system: "test2"}, _} = hd(calls)
    end

    test "returns configured token estimate" do
      Cyclium.Test.FakeSynthesizer.set_token_estimate(500)
      assert Cyclium.Test.FakeSynthesizer.estimate_tokens(%{}) == 500
    end

    test "reset clears state" do
      Cyclium.Test.FakeSynthesizer.set_response(%{"custom" => true})
      Cyclium.Test.FakeSynthesizer.synthesize(%{}, %{})
      Cyclium.Test.FakeSynthesizer.reset()

      assert {:ok, %{"response" => "mock"}} =
               Cyclium.Test.FakeSynthesizer.synthesize(%{}, %{})

      # Only one call after reset
      assert length(Cyclium.Test.FakeSynthesizer.calls()) == 1
    end
  end
end

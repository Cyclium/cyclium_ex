defmodule Cyclium.Test.SynthesizerCase do
  @moduledoc """
  Test helpers for verifying synthesizer contract compliance and
  a `FakeSynthesizer` for use in strategy tests.

  ## Usage

      defmodule MyApp.Synthesizers.ProcurementTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.SynthesizerCase

        test "synthesizer returns valid response" do
          prompt_ctx = %{system: "You are a helpful assistant", messages: []}
          episode_ctx = Cyclium.Test.StrategyCase.build_episode_ctx()

          assert_valid_synthesize(MySynthesizer, prompt_ctx, episode_ctx)
        end
      end

  ## FakeSynthesizer

  For strategy tests that need a controllable synthesizer:

      # In test setup
      Cyclium.Test.FakeSynthesizer.start_link()
      Cyclium.Test.FakeSynthesizer.set_response(%{"answer" => "42"})

      # Strategy calls synthesize/2 and gets the canned response
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.SynthesizerCase
    end
  end

  @doc """
  Assert that `synthesizer.synthesize/2` returns a valid response shape.
  """
  defmacro assert_valid_synthesize(synthesizer, prompt_ctx, episode_ctx) do
    quote bind_quoted: [
            synthesizer: synthesizer,
            prompt_ctx: prompt_ctx,
            episode_ctx: episode_ctx
          ] do
      result = synthesizer.synthesize(prompt_ctx, episode_ctx)
      Cyclium.Test.SynthesizerCase.validate_synthesize_shape!(result)
    end
  end

  @doc false
  def validate_synthesize_shape!(result) do
    case result do
      {:ok, response} when is_map(response) ->
        result

      {:error, error_class, _detail} when is_atom(error_class) ->
        result

      other ->
        raise ArgumentError, message: "synthesize/2 returned invalid shape: #{inspect(other)}"
    end
  end

  @doc """
  Assert that `synthesizer.estimate_tokens/1` returns a non-negative integer.
  """
  defmacro assert_valid_estimate_tokens(synthesizer, prompt_ctx) do
    quote bind_quoted: [synthesizer: synthesizer, prompt_ctx: prompt_ctx] do
      Cyclium.Test.SynthesizerCase.validate_estimate_tokens!(synthesizer, prompt_ctx)
    end
  end

  @doc false
  def validate_estimate_tokens!(synthesizer, prompt_ctx) do
    Code.ensure_loaded!(synthesizer)

    if function_exported?(synthesizer, :estimate_tokens, 1) do
      result = synthesizer.estimate_tokens(prompt_ctx)

      unless is_integer(result) and result >= 0 do
        raise ArgumentError,
          message: "estimate_tokens/1 must return non_neg_integer, got: #{inspect(result)}"
      end

      result
    end
  end
end

defmodule Cyclium.Test.FakeSynthesizer do
  @moduledoc """
  In-memory fake synthesizer for strategy testing.
  Records calls and returns configured responses.

  ## Usage

      setup do
        {:ok, _} = Cyclium.Test.FakeSynthesizer.start_link()
        Cyclium.Test.FakeSynthesizer.set_response(%{"answer" => "42"})
        :ok
      end
  """

  @behaviour Cyclium.Synthesizer

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{response: {:ok, %{"response" => "mock"}}, calls: [], token_estimate: 100} end,
      name: __MODULE__
    )
  end

  @doc "Set the response returned by synthesize/2."
  def set_response(response) when is_map(response) do
    Agent.update(__MODULE__, &Map.put(&1, :response, {:ok, response}))
  end

  @doc "Set an error response."
  def set_error(error_class, detail \\ %{}) do
    Agent.update(__MODULE__, &Map.put(&1, :response, {:error, error_class, detail}))
  end

  @doc "Set the token estimate returned by estimate_tokens/1."
  def set_token_estimate(n) when is_integer(n) do
    Agent.update(__MODULE__, &Map.put(&1, :token_estimate, n))
  end

  @doc "Return all recorded synthesize calls as `[{prompt_ctx, episode_ctx}]`."
  def calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  @doc "Reset calls and response to defaults."
  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{response: {:ok, %{"response" => "mock"}}, calls: [], token_estimate: 100}
    end)
  end

  @impl true
  def synthesize(prompt_ctx, episode_ctx) do
    Agent.get_and_update(__MODULE__, fn state ->
      new_state = Map.update!(state, :calls, &[{prompt_ctx, episode_ctx} | &1])
      {state.response, new_state}
    end)
  end

  @impl true
  def estimate_tokens(_prompt_ctx) do
    Agent.get(__MODULE__, & &1.token_estimate)
  end
end

defmodule Cyclium.Test.StrategyCase do
  @moduledoc """
  Test helpers for verifying strategy contract compliance.

  Validates that a strategy module correctly implements all callbacks
  defined in `Cyclium.EpisodeRunner.Strategy` and that the episode loop
  terminates within budget.

  ## Usage

      defmodule MyApp.Strategies.ClientHealthTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.StrategyCase

        @episode build_test_episode(actor_id: "test_actor", expectation_id: "health_check")
        @trigger %Cyclium.Trigger.Manual{source: "test"}

        test "init returns valid state" do
          assert_valid_init(MyStrategy, @episode, @trigger)
        end

        test "strategy terminates" do
          assert_strategy_terminates(MyStrategy, @episode, @trigger,
            max_steps: 20,
            handle_step: fn action, state -> default_step_handler(action, state) end
          )
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.StrategyCase
    end
  end

  @doc """
  Build a minimal test episode struct for strategy testing.
  """
  def build_test_episode(overrides \\ []) do
    defaults = %{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_expectation",
      trigger_type: :manual,
      trigger_ref: %{},
      status: :running,
      budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000},
      turns_used: 0,
      tokens_used: 0,
      attempts: 0,
      max_attempts: 3,
      started_at: DateTime.utc_now()
    }

    struct(Cyclium.Schemas.Episode, Map.new(overrides) |> then(&Map.merge(defaults, &1)))
  end

  @doc """
  Build a minimal episode context map matching what EpisodeRunner passes.
  """
  def build_episode_ctx(episode \\ nil) do
    episode = episode || build_test_episode()

    %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      expectation_id: episode.expectation_id,
      budget: episode.budget,
      turns_used: episode.turns_used,
      tokens_used: episode.tokens_used
    }
  end

  @doc """
  Build a minimal step struct for handle_result testing.
  """
  def build_test_step(overrides \\ []) do
    defaults = %{
      id: Ecto.UUID.generate(),
      episode_id: Ecto.UUID.generate(),
      step_no: 1,
      kind: :tool_call,
      created_at: DateTime.utc_now()
    }

    struct(Cyclium.Schemas.EpisodeStep, Map.new(overrides) |> then(&Map.merge(defaults, &1)))
  end

  @doc """
  Assert that `strategy.init/2` returns `{:ok, map()}`.
  """
  defmacro assert_valid_init(strategy, episode, trigger) do
    quote bind_quoted: [strategy: strategy, episode: episode, trigger: trigger] do
      result = strategy.init(episode, trigger)
      assert {:ok, state} = result
      assert is_map(state), "init/2 must return {:ok, map()}, got: {:ok, #{inspect(state)}}"
      state
    end
  end

  @doc """
  Assert that `strategy.next_step/2` returns a valid action shape.
  """
  defmacro assert_valid_next_step(strategy, state, episode_ctx) do
    quote bind_quoted: [strategy: strategy, state: state, episode_ctx: episode_ctx] do
      action = strategy.next_step(state, episode_ctx)
      Cyclium.Test.StrategyCase.validate_next_step_shape!(action)
      action
    end
  end

  @doc """
  Assert that `strategy.handle_result/3` returns a valid response.
  """
  defmacro assert_valid_handle_result(strategy, state, step, result) do
    quote bind_quoted: [strategy: strategy, state: state, step: step, result: result] do
      response = strategy.handle_result(state, step, result)
      Cyclium.Test.StrategyCase.validate_handle_result_shape!(response)
    end
  end

  @doc """
  Assert that `strategy.converge/2` returns valid output.
  """
  defmacro assert_valid_converge(strategy, state, episode_ctx) do
    quote bind_quoted: [strategy: strategy, state: state, episode_ctx: episode_ctx] do
      result = strategy.converge(state, episode_ctx)
      Cyclium.Test.StrategyCase.validate_converge_shape!(result)
    end
  end

  @doc """
  Simulate a strategy through the episode loop and assert it terminates
  within `max_steps`. Uses `handle_step` callback to produce mock results
  for each step action.

  ## Options

    * `:max_steps` — maximum loop iterations before failing (default: 50)
    * `:handle_step` — `(action, state) -> {:result, term()} | :skip`
      callback to produce mock step results. Defaults to `default_step_handler/2`.
  """
  defmacro assert_strategy_terminates(strategy, episode, trigger, opts \\ []) do
    quote bind_quoted: [strategy: strategy, episode: episode, trigger: trigger, opts: opts] do
      max_steps = Keyword.get(opts, :max_steps, 50)

      handle_step =
        Keyword.get(opts, :handle_step, &Cyclium.Test.StrategyCase.default_step_handler/2)

      {:ok, initial_state} = strategy.init(episode, trigger)
      ctx = Cyclium.Test.StrategyCase.build_episode_ctx(episode)

      Cyclium.Test.StrategyCase.run_loop(strategy, initial_state, ctx, handle_step, max_steps, 0)
    end
  end

  @doc false
  def run_loop(_strategy, _state, _ctx, _handle_step, max_steps, step_count)
      when step_count >= max_steps do
    flunk("Strategy did not terminate within #{max_steps} steps")
  end

  def run_loop(strategy, state, ctx, handle_step, max_steps, step_count) do
    action = strategy.next_step(state, ctx)
    validate_next_step_shape!(action)

    case action do
      :done ->
        {:ok, state, step_count}

      :converge ->
        result = strategy.converge(state, ctx)

        case result do
          {:ok, %Cyclium.ConvergeResult{}} -> {:ok, state, step_count}
          {:partial, %Cyclium.ConvergeResult{}, _} -> {:ok, state, step_count}
          other -> flunk("converge/2 returned invalid shape: #{inspect(other)}")
        end

      _ ->
        case handle_step.(action, state) do
          {:result, mock_result} ->
            step = build_test_step(step_no: step_count + 1)

            case strategy.handle_result(state, step, mock_result) do
              {:ok, new_state} ->
                new_ctx = Map.update!(ctx, :turns_used, &(&1 + 1))
                run_loop(strategy, new_state, new_ctx, handle_step, max_steps, step_count + 1)

              {:retry, new_state} ->
                run_loop(strategy, new_state, ctx, handle_step, max_steps, step_count + 1)

              {:abort, reason} ->
                {:aborted, reason, step_count}
            end

          :skip ->
            new_ctx = Map.update!(ctx, :turns_used, &(&1 + 1))
            run_loop(strategy, state, new_ctx, handle_step, max_steps, step_count + 1)
        end
    end
  end

  @doc """
  Default step handler that returns generic mock results for each action type.
  Override in tests for strategy-specific behavior.
  """
  def default_step_handler(action, _state) do
    case action do
      {:tool_call, _cap, _action, _args} -> {:result, %{"status" => "ok"}}
      {:synthesize, _ctx} -> {:result, %{"response" => "mock synthesis"}}
      {:observe, _data} -> {:result, %{"observed" => true}}
      {:output, _type, _payload} -> :skip
      {:checkpoint, _phase} -> :skip
      {:approval, _req} -> :skip
      {:wait, _ref} -> :skip
    end
  end

  @doc false
  def validate_next_step_shape!(action) do
    valid =
      case action do
        :done -> true
        :converge -> true
        {:tool_call, cap, act, args} when is_atom(cap) and is_atom(act) and is_map(args) -> true
        {:synthesize, ctx} when is_map(ctx) -> true
        {:observe, data} when is_map(data) -> true
        {:output, type, payload} when is_atom(type) and is_map(payload) -> true
        {:checkpoint, phase} when is_binary(phase) -> true
        {:approval, req} when is_map(req) -> true
        {:wait, ref} when is_map(ref) -> true
        _ -> false
      end

    unless valid do
      raise ArgumentError,
        message: "next_step/2 returned invalid action shape: #{inspect(action)}"
    end

    action
  end

  @doc false
  def validate_handle_result_shape!(response) do
    case response do
      {:ok, new_state} when is_map(new_state) ->
        response

      {:retry, new_state} when is_map(new_state) ->
        response

      {:abort, _reason} ->
        response

      other ->
        raise ArgumentError, message: "handle_result/3 returned invalid shape: #{inspect(other)}"
    end
  end

  @doc false
  def validate_converge_shape!(result) do
    case result do
      {:ok, %Cyclium.ConvergeResult{}} ->
        result

      {:partial, %Cyclium.ConvergeResult{}, failures} when is_list(failures) ->
        result

      other ->
        raise ArgumentError, message: "converge/2 returned invalid shape: #{inspect(other)}"
    end
  end

  defp flunk(message) do
    raise ArgumentError, message: message
  end
end

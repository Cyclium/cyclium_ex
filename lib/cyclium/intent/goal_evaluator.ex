defmodule Cyclium.Intent.GoalEvaluator do
  @moduledoc """
  Called after each interactive episode converges within a conversation.
  Returns whether the conversation should continue, resolve, or abandon.

  The goal's `completion_criteria.mode` picks the evaluator:

    * absent, or `"strategy_decides"` (the default) — the strategy/model signals
      resolution itself (`Cyclium.Intent.GoalEvaluator.StrategyDecides`);
    * `"required_fields"` — resolved once the listed fields are collected
      (`Cyclium.Intent.GoalEvaluator.RequiredFields`);
    * `"evaluator_callback"` — the module the expectation declares with
      `goal_evaluator: MyApp.Evaluator` in the Actor DSL (registered at boot).

  Nothing has to be configured for the default. A custom evaluator is declared
  on the expectation, in code; a module name inside the goal JSON is never
  resolved. When the goal asks for a callback and the expectation declares
  none, the conversation stays open (`:continue`) and a warning is logged.
  """

  require Logger

  alias Cyclium.Intent.GoalSpec
  alias Cyclium.ConvergeResult

  @callback evaluate(
              goal :: GoalSpec.t(),
              conversation_state :: map(),
              latest_result :: ConvergeResult.t()
            ) ::
              :continue
              | {:resolved, outcome :: binary(), result :: map()}
              | {:abandoned, reason :: binary()}

  @doc """
  Dispatches to the evaluator the goal's `completion_criteria` selects.

  `opts[:evaluator]` is the module the expectation declared (see
  `declared_for/2`); it is used for `evaluator_callback` goals and for goals
  with no mode at all.
  """
  @spec evaluate(GoalSpec.t(), map(), ConvergeResult.t(), keyword()) ::
          :continue | {:resolved, binary(), map()} | {:abandoned, binary()}
  def evaluate(%GoalSpec{} = goal, conversation_state, %ConvergeResult{} = result, opts \\ []) do
    declared = Keyword.get(opts, :evaluator)

    case mode(goal.completion_criteria) do
      "strategy_decides" ->
        __MODULE__.StrategyDecides.evaluate(goal, conversation_state, result)

      "required_fields" ->
        __MODULE__.RequiredFields.evaluate(goal, conversation_state, result)

      "evaluator_callback" ->
        custom(
          declared || inline_module(goal.completion_criteria),
          goal,
          conversation_state,
          result
        )

      nil when not is_nil(declared) ->
        custom(declared, goal, conversation_state, result)

      _ ->
        __MODULE__.StrategyDecides.evaluate(goal, conversation_state, result)
    end
  end

  @doc """
  The evaluator module an expectation declared (`goal_evaluator:` in the Actor
  DSL), or `nil`. Looks up the exact `{actor, expectation}` pair first, then any
  expectation of the actor (a conversation may not record its expectation).
  """
  @spec declared_for(atom() | binary() | nil, atom() | binary() | nil) :: module() | nil
  def declared_for(nil, _expectation_id), do: nil

  def declared_for(actor_id, expectation_id) do
    with {:ok, actor} <- to_existing_atom(actor_id) do
      exact =
        case to_existing_atom(expectation_id) do
          {:ok, exp} ->
            :persistent_term.get({:cyclium_expectation_goal_evaluator, actor, exp}, nil)

          :error ->
            nil
        end

      exact || any_for_actor(actor)
    else
      _ -> nil
    end
  end

  defp any_for_actor(actor) do
    :persistent_term.get()
    |> Enum.find_value(fn
      {{:cyclium_expectation_goal_evaluator, ^actor, _exp}, mod} -> mod
      _ -> nil
    end)
  end

  defp custom(evaluator, goal, conversation_state, result) do
    case verify(evaluator) do
      {:ok, mod} ->
        mod.evaluate(goal, conversation_state, result)

      :error ->
        Logger.warning(
          "[Cyclium.Intent.GoalEvaluator] goal asks for an evaluator callback but the " <>
            "expectation declares none (goal_evaluator:); leaving the conversation open"
        )

        :continue
    end
  end

  # An in-process goal may carry the module itself (an atom). A string from
  # JSON is a label only and is never resolved.
  defp inline_module(%{evaluator: mod}) when is_atom(mod) and not is_nil(mod), do: mod
  defp inline_module(_), do: nil

  defp verify(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :evaluate, 3),
      do: {:ok, mod},
      else: :error
  end

  defp verify(_), do: :error

  defp mode(%{mode: mode}) when is_atom(mode) and not is_nil(mode), do: Atom.to_string(mode)
  defp mode(%{mode: mode}) when is_binary(mode), do: mode
  defp mode(%{"mode" => mode}) when is_binary(mode), do: mode
  defp mode(_), do: nil

  defp to_existing_atom(nil), do: :error
  defp to_existing_atom(value) when is_atom(value), do: {:ok, value}
  defp to_existing_atom(value) when is_binary(value), do: Cyclium.AtomGuard.existing_atom(value)
end

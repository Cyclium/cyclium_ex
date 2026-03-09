defmodule Cyclium.Intent.GoalEvaluator do
  @moduledoc """
  Called after each interactive episode converges within a conversation.
  Returns whether the conversation should continue, resolve, or abandon.
  """

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
  Dispatches to the appropriate evaluator based on the goal's completion_criteria mode.
  """
  @spec evaluate(GoalSpec.t(), map(), ConvergeResult.t()) ::
          :continue | {:resolved, binary(), map()} | {:abandoned, binary()}
  def evaluate(%GoalSpec{} = goal, conversation_state, %ConvergeResult{} = result) do
    case goal.completion_criteria do
      %{mode: :strategy_decides} ->
        Cyclium.Intent.GoalEvaluator.StrategyDecides.evaluate(goal, conversation_state, result)

      %{"mode" => "strategy_decides"} ->
        Cyclium.Intent.GoalEvaluator.StrategyDecides.evaluate(goal, conversation_state, result)

      %{mode: :required_fields} ->
        Cyclium.Intent.GoalEvaluator.RequiredFields.evaluate(goal, conversation_state, result)

      %{"mode" => "required_fields"} ->
        Cyclium.Intent.GoalEvaluator.RequiredFields.evaluate(goal, conversation_state, result)

      %{mode: :evaluator_callback, evaluator: evaluator} ->
        resolve_evaluator(evaluator).evaluate(goal, conversation_state, result)

      %{"mode" => "evaluator_callback", "evaluator" => evaluator} ->
        resolve_evaluator(evaluator).evaluate(goal, conversation_state, result)

      _ ->
        Cyclium.Intent.GoalEvaluator.StrategyDecides.evaluate(goal, conversation_state, result)
    end
  end

  defp resolve_evaluator(mod) when is_atom(mod), do: mod

  defp resolve_evaluator(mod) when is_binary(mod) do
    String.to_existing_atom("Elixir.#{mod}")
  end
end

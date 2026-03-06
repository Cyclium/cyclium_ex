defmodule Cyclium.Intent.GoalEvaluator.StrategyDecides do
  @moduledoc """
  Built-in evaluator: the strategy/synthesizer signals resolution via
  the ConvergeResult's classification or meta fields.
  """

  @behaviour Cyclium.Intent.GoalEvaluator

  @impl true
  def evaluate(_goal, _conversation_state, %{classification: classification})
      when is_map(classification) do
    case classification do
      %{"conversation_resolved" => true, "outcome" => outcome, "result" => result} ->
        {:resolved, outcome, result || %{}}

      %{"conversation_resolved" => true, "outcome" => outcome} ->
        {:resolved, outcome, %{}}

      %{"conversation_abandoned" => true, "reason" => reason} ->
        {:abandoned, reason}

      %{conversation_resolved: true, outcome: outcome, result: result} ->
        {:resolved, to_string(outcome), result || %{}}

      %{conversation_resolved: true, outcome: outcome} ->
        {:resolved, to_string(outcome), %{}}

      %{conversation_abandoned: true, reason: reason} ->
        {:abandoned, to_string(reason)}

      _ ->
        :continue
    end
  end

  def evaluate(_goal, _conversation_state, _result), do: :continue
end

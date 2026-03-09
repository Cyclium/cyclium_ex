defmodule Cyclium.Intent.ConversationHook do
  @moduledoc """
  Post-converge hook for interactive episodes. Called after an interactive episode
  converges to:

  1. Increment the conversation turn counter
  2. Update collected fields from the episode result
  3. Evaluate the goal to determine if the conversation should resolve
  4. Check conversation constraints (max turns, timeout)
  """

  require Logger

  alias Cyclium.{Conversations, ConvergeResult}
  alias Cyclium.Schemas.Conversation
  alias Cyclium.Intent.{GoalEvaluator, GoalSpec}

  @spec after_converge(binary(), ConvergeResult.t(), non_neg_integer()) :: :ok
  def after_converge(conversation_id, %ConvergeResult{} = result, tokens_used \\ 0)
      when is_binary(conversation_id) do
    case Conversations.get(conversation_id) do
      nil ->
        Logger.warning("ConversationHook: conversation not found",
          conversation_id: conversation_id
        )

        :ok

      %{status: status} when status in ["resolved", "abandoned", "timed_out"] ->
        :ok

      conversation ->
        # 1. Increment turn
        Conversations.increment_turn(conversation_id, tokens_used)

        # 2. Update collected fields
        maybe_update_collected_fields(conversation_id, result)

        # 3. Evaluate goal
        evaluate_and_maybe_resolve(conversation, result)

        # 4. Check constraints
        check_constraints(conversation_id)

        :ok
    end
  end

  defp maybe_update_collected_fields(conversation_id, result) do
    new_fields =
      case result.classification do
        %{"collected_fields" => fields} when is_map(fields) -> fields
        %{collected_fields: fields} when is_map(fields) -> fields
        _ -> nil
      end

    if new_fields do
      Conversations.update_collected_fields(conversation_id, new_fields)
    end
  end

  defp evaluate_and_maybe_resolve(conversation, result) do
    goal_map = Conversation.decode_goal(conversation)

    if goal_map do
      goal = to_goal_spec(goal_map)
      collected = Conversation.decode_collected_fields(conversation)

      conversation_state = %{
        collected_fields: collected,
        turns_used: (conversation.turns_used || 0) + 1,
        tokens_used: conversation.tokens_used || 0
      }

      case GoalEvaluator.evaluate(goal, conversation_state, result) do
        :continue ->
          :ok

        {:resolved, outcome, eval_result} ->
          Conversations.resolve(conversation.id, outcome, eval_result)

        {:abandoned, reason} ->
          Conversations.abandon(conversation.id, reason)
      end
    end
  rescue
    e ->
      Logger.warning("GoalEvaluator failed: #{inspect(e)}",
        conversation_id: conversation.id
      )
  end

  defp check_constraints(conversation_id) do
    case Conversations.get(conversation_id) do
      %{status: "open"} = conv ->
        case Conversations.check_constraints(conv) do
          {:error, :budget_exceeded} ->
            Conversations.timeout(conversation_id)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp to_goal_spec(map) when is_map(map) do
    %GoalSpec{
      type: map["type"] || "assist",
      description: map["description"],
      terminal_outcomes: map["terminal_outcomes"] || %{},
      completion_criteria: map["completion_criteria"] || %{},
      constraints: map["constraints"] || %{},
      context: map["context"] || %{}
    }
  end
end

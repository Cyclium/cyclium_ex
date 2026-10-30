defmodule Cyclium.InteractiveHistoryDbTest do
  @moduledoc """
  The interactive template assembles a conversation's earlier finished turns —
  each user message, its reply, and the tools it called — as history.
  """
  use Cyclium.DataCase

  alias Cyclium.Strategy.Template.Interactive

  defp turn(conv_id, n, opts \\ []) do
    episode =
      insert_episode(%{
        actor_id: "history_actor",
        conversation_id: conv_id,
        trigger_type: :interactive,
        trigger_ref: %{"conversation_id" => conv_id, "message" => "question #{n}"},
        status: Keyword.get(opts, :status, :done),
        summary: "answer #{n}",
        started_at: DateTime.add(~U[2026-01-01 00:00:00Z], n, :second)
      })

    for {tool, i} <- Enum.with_index(Keyword.get(opts, :tools, []), 1) do
      insert_step(%{episode_id: episode.id, step_no: i, kind: :tool_call, tool_name: tool})
    end

    episode
  end

  defp context(conv_id, config \\ %{}, history \\ []) do
    state = %{
      phase: :context_assembly,
      strategy_config: config,
      message: "follow-up",
      principal: nil,
      history: history,
      conversation_id: conv_id,
      conversation: nil,
      goal: nil
    }

    {:observe, context} =
      Interactive.next_step(state, %{actor_id: "history_actor", episode_id: "current"})

    context
  end

  test "earlier turns arrive as user and assistant entries, with their tools" do
    conv_id = Ecto.UUID.generate()
    turn(conv_id, 1, tools: ["crm.search"])
    turn(conv_id, 2)

    assert [
             %{role: "user", content: "question 1"},
             %{role: "assistant", content: "answer 1", tools: ["crm.search"]},
             %{role: "user", content: "question 2"},
             %{role: "assistant", content: "answer 2", tools: []}
           ] = context(conv_id).history
  end

  test "a turn a trusted caller started is a system entry" do
    conv_id = Ecto.UUID.generate()

    insert_episode(%{
      actor_id: "history_actor",
      conversation_id: conv_id,
      trigger_type: :interactive,
      trigger_ref: %{"conversation_id" => conv_id, "message" => "nudge", "system" => true},
      status: :done,
      summary: "nudged",
      started_at: ~U[2026-01-01 00:00:01Z]
    })

    assert [%{role: "system", content: "nudge"}, %{role: "assistant", content: "nudged"}] =
             context(conv_id).history
  end

  test "prior_summaries is still assembled" do
    conv_id = Ecto.UUID.generate()
    turn(conv_id, 1)

    assert [%{summary: "answer 1"}] = context(conv_id).prior_summaries
  end

  test "unfinished turns are left out" do
    conv_id = Ecto.UUID.generate()
    turn(conv_id, 1)
    turn(conv_id, 2, status: :failed)

    assert length(context(conv_id).history) == 2
  end

  test "history_turns keeps the most recent turns" do
    conv_id = Ecto.UUID.generate()
    for n <- 1..5, do: turn(conv_id, n)

    history = context(conv_id, %{"history_turns" => 2}).history

    assert Enum.map(history, & &1.content) == ["question 4", "answer 4", "question 5", "answer 5"]
    assert context(conv_id, %{"history_turns" => 0}).history == []
  end

  test "a trigger that carries history is used as given" do
    conv_id = Ecto.UUID.generate()
    turn(conv_id, 1)
    given = [%{role: "user", content: "from the trigger"}]

    assert context(conv_id, %{}, given).history == given
  end
end

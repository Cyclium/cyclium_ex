defmodule Cyclium.ConversationTokenRollupDbTest do
  @moduledoc """
  Regression test for the conversation token rollup. Token spend is incremented
  on the DB row mid-loop (increment_budget/2), so the in-memory episode struct is
  stale by converge time. maybe_run_conversation_hook/2 must reload it before
  rolling tokens up onto the conversation — otherwise tokens_used stays 0 (and
  any max_total_tokens goal constraint is silently inert).
  """
  use Cyclium.DataCase

  alias Cyclium.{Conversations, Episodes, EpisodeRunner}
  alias Cyclium.ConvergeResult

  # Synthesizer that reports API usage so the runner increments the token budget.
  defmodule TokenSynth do
    def synthesize(_prompt_ctx, _episode_ctx) do
      {:ok, %{usage: %{input_tokens: 100, output_tokens: 88}}}
    end
  end

  # Minimal strategy: one synthesis step (which costs tokens), then converge.
  defmodule TokenStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{phase: :synth}}

    def next_step(%{phase: :synth}, _ctx), do: {:synthesize, %{task: :interpret}}
    def next_step(%{phase: :done}, _ctx), do: :converge

    def handle_result(%{phase: :synth} = state, _step, {:ok, _result}),
      do: {:ok, %{state | phase: :done}}

    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx) do
      {:ok,
       %ConvergeResult{
         summary: "ok",
         classification: %{},
         confidence: 1.0,
         outputs: [],
         findings: []
       }}
    end
  end

  defp start_conversation do
    {:ok, conv} =
      Conversations.start(%{
        actor_id: "rollup_actor",
        name: "Rollup",
        principal: %{"type" => "user", "id" => "user_1"}
      })

    conv
  end

  test "token spend rolls up onto the conversation after converge" do
    conv = start_conversation()

    # tokens_used: 0 at load time — the loop must increment it before converge.
    episode =
      insert_episode(%{
        actor_id: "rollup_actor",
        conversation_id: conv.id,
        trigger_type: :interactive,
        status: :running,
        tokens_used: 0,
        budget: %{"max_turns" => 10, "max_tokens" => 10_000, "max_wall_ms" => 120_000}
      })

    assert {:ok, _} =
             EpisodeRunner.execute_loop(episode, TokenStrategy, %{phase: :synth},
               synthesizer: TokenSynth
             )

    # The episode recorded the spend...
    assert Episodes.get!(episode.id).tokens_used == 188

    # ...and the conversation rolled it up (not stuck at 0), with one turn.
    rolled = Conversations.get!(conv.id)
    assert rolled.tokens_used == 188
    assert rolled.turns_used == 1
  end
end

defmodule Cyclium.LoopDetectionDbTest do
  @moduledoc """
  Loop detection fires only on a repeating action cycle that makes NO budget
  progress, and can be disabled per-expectation via `loop_detection: false`.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, EpisodeRunner}
  alias Cyclium.Schemas.Episode

  # Repeats an identical, token-free action forever (a stuck loop).
  defmodule PollLoopStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_episode, _trigger), do: {:ok, %{}}
    def next_step(_state, _ctx), do: {:observe, %{poll: true}}
    def handle_result(state, _step, _result), do: {:ok, state}
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  # Repeats an identical synthesize action, but each one consumes tokens — so
  # it's making budget progress and must NOT be flagged as a loop.
  defmodule SynthLoopStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_episode, _trigger), do: {:ok, %{}}
    def next_step(_state, _ctx), do: {:synthesize, %{p: 1}}
    def handle_result(state, _step, _result), do: {:ok, state}
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  defmodule CostlySynth do
    @behaviour Cyclium.Synthesizer
    def synthesize(_prompt, _ctx), do: {:ok, %{}}
    def estimate_tokens(_prompt), do: 10
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.LoopPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.LoopPubSub)
    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)
    :ok
  end

  defp budget(overrides),
    do:
      Map.merge(%{"max_turns" => 50, "max_tokens" => 1_000, "max_wall_ms" => 120_000}, overrides)

  test "a token-free repeating cycle is detected as a loop" do
    episode = insert_episode(%{actor_id: "loop_a", expectation_id: "e", budget: budget(%{})})

    assert {:error, :loop_detected} = EpisodeRunner.execute_loop(episode, PollLoopStrategy, %{})

    ep = Repo.get!(Episode, episode.id)
    assert ep.status == :failed
    assert ep.error_class == "loop_detected"
  end

  test "a repeating cycle that consumes tokens is NOT a loop (bounded by budget instead)" do
    episode =
      insert_episode(%{
        actor_id: "loop_b",
        expectation_id: "e",
        budget: budget(%{"max_tokens" => 50})
      })

    # Each identical synthesize costs 10 tokens → progress → not a loop; the
    # token budget stops it.
    assert {:error, :budget_exceeded} =
             EpisodeRunner.execute_loop(episode, SynthLoopStrategy, %{}, synthesizer: CostlySynth)

    ep = Repo.get!(Episode, episode.id)
    assert ep.error_class == "budget_exceeded"
  end

  test "loop_detection: false disables detection for that expectation" do
    # Register the off switch for this actor/expectation (atoms must exist).
    actor = :loop_off_actor
    exp = :loop_off_exp
    :persistent_term.put({:cyclium_expectation_loop_detection, actor, exp}, false)
    on_exit(fn -> :persistent_term.erase({:cyclium_expectation_loop_detection, actor, exp}) end)

    episode =
      insert_episode(%{
        actor_id: to_string(actor),
        expectation_id: to_string(exp),
        budget: budget(%{"max_turns" => 8})
      })

    # The same token-free cycle as test 1, but detection is off — it runs until
    # the turn budget stops it rather than being flagged as a loop.
    assert {:error, :budget_exceeded} = EpisodeRunner.execute_loop(episode, PollLoopStrategy, %{})

    assert Repo.get!(Episode, episode.id).error_class == "budget_exceeded"
  end
end

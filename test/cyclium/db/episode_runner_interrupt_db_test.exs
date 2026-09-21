defmodule Cyclium.EpisodeRunnerInterruptDbTest do
  @moduledoc """
  A graceful shutdown mid-run is not a failure of the episode.

  Before this, a `:shutdown` EXIT at a step boundary journaled `episode_failed`
  and set the row `:failed` (`process_terminated`) — which put the episode out of
  reach of `Cyclium.Recovery.sweep/1`, since the sweep lists `:running` rows only.
  So an expectation's `recovery_policy: :restart` never applied to the most common
  way a run gets cut off: a deploy. Now the loop leaves the row `:running`, stamps
  `phase: "interrupted"`, releases the claim and broadcasts, and the sweep treats
  that phase as stale immediately.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, EpisodeRunner, Episodes}

  # Simulates the supervisor asking the task to stop between two steps: the first
  # step queues a `:shutdown` EXIT in the loop's own mailbox, exactly as
  # `Process.flag(:trap_exit, true)` delivers one, so the next drain sees it.
  defmodule ShutdownMidRunStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{phase: :first}}

    @impl true
    def next_step(%{phase: :first}, _ctx) do
      send(self(), {:EXIT, self(), :shutdown})
      {:observe, %{"event" => "first"}}
    end

    def next_step(%{phase: :second}, _ctx), do: {:observe, %{"event" => "never reached"}}

    @impl true
    def handle_result(%{phase: :first} = state, _step, {:ok, _}),
      do: {:ok, %{state | phase: :second}}

    def handle_result(state, _step, _result), do: {:ok, state}

    @impl true
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{summary: "never"}}
  end

  # The same, with the tuple form a supervisor uses for a bounded shutdown.
  defmodule TupleShutdownStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{}}

    @impl true
    def next_step(_state, _ctx) do
      send(self(), {:EXIT, self(), {:shutdown, :node_draining}})
      {:observe, %{"event" => "first"}}
    end

    @impl true
    def handle_result(state, _step, _result), do: {:ok, state}

    @impl true
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{summary: "never"}}
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.InterruptTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.InterruptTestPubSub)
    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)

    Cyclium.Bus.subscribe()
    :ok
  end

  defp running_episode do
    insert_episode(%{
      actor_id: "interrupt_actor",
      expectation_id: "long_work",
      status: :running,
      budget: %{"max_turns" => 10, "max_tokens" => 10_000, "max_wall_ms" => 120_000}
    })
  end

  test "a :shutdown exit leaves the episode running, marked interrupted, and says so" do
    episode = running_episode()

    assert {:error, :interrupted} =
             EpisodeRunner.execute_loop(episode, ShutdownMidRunStrategy, %{phase: :first})

    reloaded = Episodes.get!(episode.id)
    assert reloaded.status == :running
    assert reloaded.phase == "interrupted"
    assert is_nil(reloaded.error_class)

    # The task's `after` block reads this to leave the row alone on exit.
    assert Process.get(:cyclium_interrupted) == true

    assert_receive {:bus, "episode.interrupted",
                    %{episode_id: id, status: :running, phase: "interrupted"}}

    assert id == episode.id
    refute_receive {:bus, "episode.failed", _}, 50

    # Nothing was journaled as a failure — the timeline shows the first step and
    # then the interruption marker a step feed renders.
    assert [%{kind: :observation}, %{kind: :observation, result_ref: %{"event" => "interrupted"}}] =
             episode.id |> Episodes.list_steps() |> Enum.sort_by(& &1.step_no)
  end

  # `Cyclium.EpisodeDrainer` has done the hand-off for the whole node; the task
  # only has to stop. No second set of writes.
  defmodule DrainedStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{}}

    @impl true
    def next_step(_state, _ctx) do
      send(self(), :cyclium_drained)
      {:observe, %{"event" => "first"}}
    end

    @impl true
    def handle_result(state, _step, _result), do: {:ok, state}

    @impl true
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{summary: "never"}}
  end

  test "a drained task stops without writing anything of its own" do
    episode = running_episode()

    assert {:error, :interrupted} = EpisodeRunner.execute_loop(episode, DrainedStrategy, %{})
    assert Process.get(:cyclium_interrupted) == true

    # The drainer's writes are not this process's job: the row is untouched
    # and only the strategy's own step is in the journal.
    assert Episodes.get!(episode.id).phase == nil

    assert [%{kind: :observation, result_ref: %{"event" => "first"}}] =
             Episodes.list_steps(episode.id)

    refute_receive {:bus, "episode.interrupted", _}, 50
  end

  test "the {:shutdown, reason} form is an interruption too" do
    episode = running_episode()

    assert {:error, :interrupted} =
             EpisodeRunner.execute_loop(episode, TupleShutdownStrategy, %{})

    assert Episodes.get!(episode.id).phase == "interrupted"
  end

  test "an interrupted episode is stale to the sweep at once, whatever its recency" do
    episode = running_episode()

    assert {:error, :interrupted} =
             EpisodeRunner.execute_loop(episode, ShutdownMidRunStrategy, %{phase: :first})

    # A step was journaled a moment ago, so by recency alone this is fresh.
    ids = Episodes.list_stale_running(:timer.hours(1)) |> Enum.map(& &1.id)
    assert episode.id in ids
  end
end

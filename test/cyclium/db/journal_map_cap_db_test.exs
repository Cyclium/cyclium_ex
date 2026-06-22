defmodule Cyclium.JournalMapCapDbTest do
  @moduledoc """
  A journaled step's `:map` fields must stay under the Tds nvarchar parameter
  boundary (~4000 bytes / ~2000 UTF-16 chars). Past it, SQL Server silently
  truncates the value before it reaches the nvarchar(max) column, so it fails to
  JSON-decode on read and crashes every reader of the row. (SQLite doesn't
  truncate, so this asserts the cyclium-side cap shrinks the value.)
  """
  use Cyclium.DataCase

  import Ecto.Query

  alias Cyclium.{ConvergeResult, EpisodeRunner}
  alias Cyclium.Schemas.EpisodeStep

  defmodule BigSummaryStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{}}

    @impl true
    def next_step(_state, _ctx), do: :converge

    @impl true
    def handle_result(state, _step, _result), do: {:ok, state}

    @impl true
    def converge(_state, _ctx) do
      {:ok,
       %ConvergeResult{
         classification: %{"primary" => "explain_only"},
         confidence: 1.0,
         # Far past the ~2000-char boundary — the episode_completed step's
         # result_ref carries this summary, so it must be capped before insert.
         summary: String.duplicate("abcde ", 1_000),
         findings: [],
         outputs: []
       }}
    end
  end

  defmodule ObserveStructStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{observed: false}}

    @impl true
    def next_step(%{observed: false}, _ctx) do
      # An oversized result_ref whose values include structs (DateTime) — structs
      # are maps but not Enumerable, so the cap must treat them as leaves.
      {:observe,
       %{
         "blob" => String.duplicate("z", 6_000),
         "ts" => DateTime.utc_now(),
         "nested" => %{"when" => DateTime.utc_now(), "label" => "x"}
       }}
    end

    def next_step(_state, _ctx), do: :converge

    @impl true
    def handle_result(state, _step, _result), do: {:ok, %{state | observed: true}}

    @impl true
    def converge(_state, _ctx) do
      {:ok,
       %ConvergeResult{
         classification: %{"primary" => "ok"},
         confidence: 1.0,
         summary: "ok",
         findings: [],
         outputs: []
       }}
    end
  end

  test "caps an oversized :map with struct (DateTime) values without crashing" do
    episode =
      insert_episode(%{
        actor_id: "cap_struct_actor",
        expectation_id: "do_work",
        log_strategy: "full_debug",
        budget: %{"max_turns" => 5, "max_tokens" => 1_000, "max_wall_ms" => 10_000}
      })

    assert {:ok, _} =
             EpisodeRunner.execute_loop(episode, ObserveStructStrategy, %{observed: false})

    steps =
      from(s in EpisodeStep, where: s.episode_id == ^episode.id)
      |> Repo.all()

    for step <- steps, not is_nil(step.result_ref) do
      assert step.result_ref |> Jason.encode!() |> String.length() <= 1_900
    end
  end

  test "journaled :map fields are capped under the Tds nvarchar boundary" do
    episode =
      insert_episode(%{
        actor_id: "cap_actor",
        expectation_id: "do_work",
        log_strategy: "full_debug",
        budget: %{"max_turns" => 5, "max_tokens" => 1_000, "max_wall_ms" => 10_000}
      })

    EpisodeRunner.execute_loop(episode, BigSummaryStrategy, %{})

    steps =
      from(s in EpisodeStep, where: s.episode_id == ^episode.id)
      |> Repo.all()

    # Every stored :map reads back as valid JSON and within the cap.
    for step <- steps, not is_nil(step.result_ref) do
      assert step.result_ref |> Jason.encode!() |> String.length() <= 1_900
    end

    # The oversized completion result_ref degraded to the truncation marker
    # rather than being stored corrupt.
    assert Enum.any?(steps, &(is_map(&1.result_ref) and &1.result_ref["_truncated"] == true))

    # The full reply is preserved on the episode itself, not the capped step.
    assert String.length(Cyclium.Episodes.get!(episode.id).summary) > 4_000
  end
end

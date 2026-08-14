defmodule Cyclium.JournalMapCapDbTest do
  @moduledoc """
  A journaled step's `:map` fields (`args_redacted` / `result_ref` /
  `error_detail`) are bounded by a runaway guard (`@map_field_max_chars`,
  1,000,000 chars) before insert. This is NOT a driver limit — the columns are
  `nvarchar(max)` and Tds PLP-chunks oversized parameters, so large JSON
  round-trips intact — it only stops a pathological blob from wedging every
  reader of the row. A value past the guard degrades to a `%{"_truncated" =>
  true}` marker rather than being stored, and struct leaves (e.g. `DateTime`) in
  the walked map are treated as opaque leaves so capping never calls
  `Enum.reduce` on a non-Enumerable struct.
  """
  use Cyclium.DataCase

  import Ecto.Query

  alias Cyclium.{ConvergeResult, EpisodeRunner}
  alias Cyclium.Schemas.EpisodeStep

  # Must match @map_field_max_chars in Cyclium.EpisodeRunner. A stored :map's
  # JSON stays within this (plus the marker wrapper's small overhead).
  @cap 1_000_000

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
         # Far past the 1,000,000-char guard (~1.2M chars) — the
         # episode_completed step's result_ref carries this summary, so it must
         # be capped before insert.
         summary: String.duplicate("abcde ", 200_000),
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
      # An oversized result_ref (past the 1,000,000-char guard) whose values
      # include structs (DateTime) — structs are maps but not Enumerable, so the
      # cap must treat them as leaves while walking the map to truncate it.
      {:observe,
       %{
         "blob" => String.duplicate("z", 1_001_000),
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
      assert step.result_ref |> Jason.encode!() |> String.length() <= @cap + 100
    end
  end

  test "journaled :map fields are capped under the runaway guard" do
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
      assert step.result_ref |> Jason.encode!() |> String.length() <= @cap + 100
    end

    # The oversized completion result_ref degraded to the truncation marker
    # rather than being stored corrupt.
    assert Enum.any?(steps, &(is_map(&1.result_ref) and &1.result_ref["_truncated"] == true))

    # The full reply is preserved on the episode itself, not the capped step.
    assert String.length(Cyclium.Episodes.get!(episode.id).summary) > @cap
  end
end

defmodule Cyclium.CheckpointVersionDbTest do
  @moduledoc """
  save_checkpoint stamps the version the *registered* checkpoint schema
  currently writes (resolved with the same lookup EpisodeTask uses on restore),
  so `migrate_to_current/2` sees the true on-disk version.

  The version-stamping tests use a strategy that BLOCKS after checkpointing —
  completed episodes delete their checkpoints (see the cleanup describe), so a
  run-to-done strategy would leave nothing to assert on.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, EpisodeRunner}
  alias Cyclium.Schemas.EpisodeCheckpoint

  defmodule V3Schema do
    use Cyclium.CheckpointSchema, version: 3

    def migrate(_from, state), do: {:ok, state}
  end

  defmodule ActorLevelSchema do
    use Cyclium.CheckpointSchema, version: 2

    def migrate(_from, state), do: {:ok, state}
  end

  # Checkpoints "go", then parks on an approval so the episode stays :blocked
  # and the checkpoint row survives for assertions.
  defmodule CheckpointThenBlockStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{phase: :go}}
    def next_step(%{phase: :go}, _ctx), do: {:checkpoint, "go"}
    def next_step(%{phase: :hold}, _ctx), do: {:approval, %{reason: "hold for assertions"}}

    def handle_result(%{phase: :go} = state, %{kind: :checkpoint}, {:ok, "go"}),
      do: {:ok, %{state | phase: :hold}}

    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  # Checkpoints "go", then completes normally.
  defmodule CheckpointThenDoneStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{phase: :go}}
    def next_step(%{phase: :go}, _ctx), do: {:checkpoint, "go"}
    def next_step(%{phase: :done}, _ctx), do: :converge

    def handle_result(%{phase: :go} = state, %{kind: :checkpoint}, {:ok, "go"}),
      do: {:ok, %{state | phase: :done}}

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

  # Checkpoints "go", then aborts — the episode fails and must KEEP its
  # checkpoints (a re-enqueue with resume: true resumes from them).
  defmodule CheckpointThenAbortStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{phase: :go}}
    def next_step(%{phase: :go}, _ctx), do: {:checkpoint, "go"}

    def handle_result(%{phase: :go}, %{kind: :checkpoint}, {:ok, "go"}),
      do: {:abort, "boom"}

    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.CheckpointVersionPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.CheckpointVersionPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :checkpoint_schemas)
    end)

    :ok
  end

  describe "schema version stamping" do
    test "stamps the {actor_id, expectation_id}-registered schema's version" do
      Application.put_env(:cyclium, :checkpoint_schemas, %{
        {"test_actor", "test_exp"} => V3Schema
      })

      episode = insert_episode(%{dedupe_key: "cp-v3"})

      assert {:blocked, _} =
               EpisodeRunner.execute_loop(episode, CheckpointThenBlockStrategy, %{phase: :go})

      cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
      assert cp.schema_version == 3
    end

    test "falls back to the actor_id-level registration" do
      Application.put_env(:cyclium, :checkpoint_schemas, %{"test_actor" => ActorLevelSchema})

      episode = insert_episode(%{dedupe_key: "cp-v2"})

      assert {:blocked, _} =
               EpisodeRunner.execute_loop(episode, CheckpointThenBlockStrategy, %{phase: :go})

      cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
      assert cp.schema_version == 2
    end

    test "defaults to version 1 when no schema is registered" do
      episode = insert_episode(%{dedupe_key: "cp-v1"})

      assert {:blocked, _} =
               EpisodeRunner.execute_loop(episode, CheckpointThenBlockStrategy, %{phase: :go})

      cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
      assert cp.schema_version == 1
    end
  end

  describe "checkpoint cleanup on terminal status" do
    test "a completed episode deletes its checkpoints" do
      episode = insert_episode(%{dedupe_key: "cp-done"})

      assert {:ok, _} =
               EpisodeRunner.execute_loop(episode, CheckpointThenDoneStrategy, %{phase: :go})

      assert Repo.get!(Cyclium.Schemas.Episode, episode.id).status == :done

      assert Repo.aggregate(
               from(c in EpisodeCheckpoint, where: c.episode_id == ^episode.id),
               :count
             ) == 0
    end

    test "a failed episode keeps its checkpoints for resume" do
      episode = insert_episode(%{dedupe_key: "cp-fail"})

      assert {:error, _} =
               EpisodeRunner.execute_loop(episode, CheckpointThenAbortStrategy, %{phase: :go})

      assert Repo.get!(Cyclium.Schemas.Episode, episode.id).status == :failed
      assert Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
    end
  end
end

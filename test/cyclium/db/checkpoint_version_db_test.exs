defmodule Cyclium.CheckpointVersionDbTest do
  @moduledoc """
  save_checkpoint stamps the version the *registered* checkpoint schema
  currently writes (resolved with the same lookup EpisodeTask uses on restore),
  so `migrate_to_current/2` sees the true on-disk version. Previously every
  checkpoint was hardcoded to schema_version 1, which made real migrations
  impossible to trigger.
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

  defmodule CheckpointStrategy do
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

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.CheckpointVersionPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.CheckpointVersionPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :checkpoint_schemas)
    end)

    :ok
  end

  test "stamps the {actor_id, expectation_id}-registered schema's version" do
    Application.put_env(:cyclium, :checkpoint_schemas, %{
      {"test_actor", "test_exp"} => V3Schema
    })

    episode = insert_episode(%{dedupe_key: "cp-v3"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, CheckpointStrategy, %{phase: :go})

    cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
    assert cp.schema_version == 3
  end

  test "falls back to the actor_id-level registration" do
    Application.put_env(:cyclium, :checkpoint_schemas, %{"test_actor" => ActorLevelSchema})

    episode = insert_episode(%{dedupe_key: "cp-v2"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, CheckpointStrategy, %{phase: :go})

    cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
    assert cp.schema_version == 2
  end

  test "defaults to version 1 when no schema is registered" do
    episode = insert_episode(%{dedupe_key: "cp-v1"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, CheckpointStrategy, %{phase: :go})

    cp = Repo.get_by!(EpisodeCheckpoint, episode_id: episode.id, phase: "go")
    assert cp.schema_version == 1
  end
end

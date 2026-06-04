defmodule Cyclium.EpisodeRunnerFencingDbTest do
  @moduledoc """
  Covers the steal-window fixes:

    * a lost work claim (signalled mid-run, or detected at post-converge) aborts
      the episode before it persists findings or delivers outputs, and does NOT
      clobber the new owner's episode row;
    * a :blocked transition checkpoints the at-block state so resume doesn't
      replay the steps leading up to it.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, EpisodeRunner, OutputProposal}
  alias Cyclium.Schemas.{Episode, EpisodeCheckpoint}
  alias Cyclium.WorkClaims.EctoClaims

  defmodule DeliverStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_episode, _trigger), do: {:ok, %{}}
    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx) do
      {:ok,
       %ConvergeResult{
         classification: %{"primary" => "ok"},
         confidence: 1.0,
         summary: "done",
         findings: [],
         outputs: [%OutputProposal{type: :email, dedupe_key: "out-1", payload: %{}}]
       }}
    end
  end

  defmodule BlockStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_episode, _trigger), do: {:ok, %{phase: "await", gathered: "important"}}
    def next_step(_state, _ctx), do: {:approval, %{reason: "needs sign-off"}}
    def handle_result(state, _step, _result), do: {:ok, state}
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  defmodule RecordingAdapter do
    @behaviour Cyclium.Output.Adapter
    # deliver/3 runs inline in the test process, so this reaches the test mailbox.
    def deliver(type, _payload, _ctx) do
      send(self(), {:delivered, type})
      {:ok, %{id: "x"}}
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.FencingPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.FencingPubSub)
    Application.put_env(:cyclium, :output_adapters, %{email: RecordingAdapter})

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :output_adapters)
      Application.delete_env(:cyclium, :work_claims)
      Application.delete_env(:cyclium, :node_identity)
    end)

    :ok
  end

  describe "abort on claim loss" do
    test "a {:cyclium_claim_lost, _} signal aborts before delivery without touching the episode" do
      episode = insert_episode(%{dedupe_key: "k1"})
      send(self(), {:cyclium_claim_lost, "k1"})

      assert {:error, :claim_lost} = EpisodeRunner.execute_loop(episode, DeliverStrategy, %{})

      refute_received {:delivered, _}
      # Left :running for the new owner to drive — not marked failed/done by us.
      assert Repo.get!(Episode, episode.id).status == :running
      assert Process.get(:cyclium_claim_lost) == true
    end

    test "post_converge re-assert: a stolen lease skips findings and outputs" do
      Application.put_env(:cyclium, :work_claims, EctoClaims)
      Application.put_env(:cyclium, :node_identity, "this_node")

      episode = insert_episode(%{dedupe_key: "k2"})
      # Another node owns the lease — this_node is no longer the owner.
      {:ok, _} = EctoClaims.acquire("k2", "other_node")

      assert {:error, :claim_lost} = EpisodeRunner.execute_loop(episode, DeliverStrategy, %{})

      refute_received {:delivered, _}
      assert Repo.get!(Episode, episode.id).status == :running
    end

    test "the rightful owner delivers normally (control)" do
      Application.put_env(:cyclium, :work_claims, EctoClaims)
      Application.put_env(:cyclium, :node_identity, "this_node")

      episode = insert_episode(%{dedupe_key: "k3"})
      {:ok, _} = EctoClaims.acquire("k3", "this_node")

      assert {:ok, _} = EpisodeRunner.execute_loop(episode, DeliverStrategy, %{})

      assert_received {:delivered, :email}
      assert Repo.get!(Episode, episode.id).status == :done
    end
  end

  describe "checkpoint before :blocked" do
    test "an approval block writes a __blocked__ checkpoint with the at-block state" do
      episode = insert_episode(%{dedupe_key: "k4"})
      # execute_loop receives the running state directly (init runs in EpisodeTask).
      state = %{phase: "await", gathered: "important"}

      assert {:blocked, _state} = EpisodeRunner.execute_loop(episode, BlockStrategy, state)

      cp = Repo.get_by(EpisodeCheckpoint, episode_id: episode.id, phase: "__blocked__")
      assert cp
      assert cp.state["phase"] == "await"
      assert cp.state["gathered"] == "important"
    end
  end
end

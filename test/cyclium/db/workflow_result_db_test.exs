defmodule Cyclium.WorkflowResultDbTest do
  use Cyclium.DataCase

  alias Cyclium.EpisodeRunner
  alias Cyclium.Schemas.Episode

  defmodule ResultStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_e, _t), do: {:ok, %{order_total: 120}}
    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx),
      do: {:ok, %Cyclium.ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}

    def workflow_result(state, converge_result),
      do: %{order_total: state.order_total, summary: "#{converge_result.summary}!"}
  end

  defmodule RaisingResultStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_e, _t), do: {:ok, %{}}
    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx),
      do: {:ok, %Cyclium.ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}

    def workflow_result(_state, _converge_result), do: raise("boom")
  end

  test "a workflow step's episode keeps its strategy's workflow_result in metadata" do
    episode =
      insert_episode(%{
        actor_id: "workflow_result_actor",
        trigger_type: :workflow,
        workflow_instance_id: Ecto.UUID.generate(),
        workflow_step_id: "validate"
      })

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, ResultStrategy, %{order_total: 120})

    episode = Repo.get!(Episode, episode.id)
    assert episode.status == :done
    assert episode.metadata["workflow_result"] == %{"order_total" => 120, "summary" => "ok!"}
  end

  test "an episode outside a workflow does not call workflow_result" do
    episode = insert_episode(%{actor_id: "workflow_result_actor"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, ResultStrategy, %{order_total: 120})

    refute (Repo.get!(Episode, episode.id).metadata || %{})["workflow_result"]
  end

  test "a workflow_result that raises leaves the episode to complete with the default result" do
    episode =
      insert_episode(%{
        actor_id: "workflow_result_actor",
        trigger_type: :workflow,
        workflow_instance_id: Ecto.UUID.generate(),
        workflow_step_id: "validate"
      })

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, RaisingResultStrategy, %{})

    episode = Repo.get!(Episode, episode.id)
    assert episode.status == :done
    refute (episode.metadata || %{})["workflow_result"]
  end
end

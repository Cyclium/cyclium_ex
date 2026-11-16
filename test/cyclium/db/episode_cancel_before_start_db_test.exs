defmodule Cyclium.EpisodeCancelBeforeStartDbTest do
  @moduledoc """
  A cancel requested before an episode's worker starts (still queued, deferred,
  or waiting on a retry) is recorded on the row, and the worker cancels the
  episode before its first step instead of running it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyclium.Schemas.{Episode, EpisodeStep}
  alias Cyclium.Test.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:cyclium, :repo, Repo)

    start_supervised!({Phoenix.PubSub, name: Cyclium.CancelBeforeStartPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.CancelBeforeStartPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :repo)
    end)

    :ok
  end

  defp insert_episode(attrs) do
    %Episode{}
    |> Episode.changeset(
      Map.merge(
        %{
          actor_id: "cancel_before_start_actor",
          expectation_id: "never_runs",
          trigger_type: :manual,
          status: :running,
          started_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp run_task(episode_id) do
    {:ok, pid} = Cyclium.EpisodeTask.start_link(episode_id: episode_id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  defp journal(episode_id) do
    Repo.all(from(s in EpisodeStep, where: s.episode_id == ^episode_id, order_by: s.step_no))
  end

  test "request_cancel records the request on a running episode" do
    episode = insert_episode(%{})

    assert {:ok, :requested} = Cyclium.Episodes.request_cancel(episode.id, "operator_stop")

    episode = Repo.get!(Episode, episode.id)
    assert Cyclium.Episodes.cancel_requested(episode) == "operator_stop"
    assert episode.status == :running
  end

  test "a worker that starts after the request cancels the episode without running it" do
    episode = insert_episode(%{})
    {:ok, :requested} = Cyclium.Episodes.request_cancel(episode.id, "workflow_canceled")

    run_task(episode.id)

    episode = Repo.get!(Episode, episode.id)
    assert episode.status == :canceled

    assert [%EpisodeStep{kind: :episode_failed, error_class: "canceled"} = step] =
             journal(episode.id)

    assert step.error_detail["reason"] == "workflow_canceled"
  end

  test "a worker that starts for an already canceled episode leaves it alone" do
    episode = insert_episode(%{status: :canceled})

    run_task(episode.id)

    assert Repo.get!(Episode, episode.id).status == :canceled
    assert journal(episode.id) == []
  end
end

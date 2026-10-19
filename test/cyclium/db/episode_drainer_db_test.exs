defmodule Cyclium.EpisodeDrainerDbTest do
  @moduledoc """
  The node-level shutdown hand-off: every running episode on the node is marked
  `interrupted`, given one journal marker, and told to stop — in three
  statements for the lot rather than three per task.
  """
  use Cyclium.DataCase

  alias Cyclium.{EpisodeDrainer, Episodes}
  alias Cyclium.Schemas.EpisodeStep

  setup do
    start_supervised!({Registry, keys: :unique, name: Cyclium.EpisodeProcessRegistry})
    start_supervised!({Phoenix.PubSub, name: Cyclium.DrainerTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.DrainerTestPubSub)
    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)

    Cyclium.Bus.subscribe()
    :ok
  end

  # A stand-in for an episode task: registers, then waits to be drained and
  # reports back to the test.
  defp fake_task(episode) do
    test = self()

    pid =
      spawn_link(fn ->
        EpisodeDrainer.register(episode)
        send(test, {:registered, episode.id})

        receive do
          :cyclium_drained -> send(test, {:drained, episode.id})
        end
      end)

    assert_receive {:registered, _}
    pid
  end

  defp steps(episode_id) do
    episode_id |> Episodes.list_steps() |> Enum.sort_by(& &1.step_no)
  end

  test "drains every registered episode with one marker each, numbered after its last step" do
    a = insert_episode(%{actor_id: "drain_actor", status: :running})
    b = insert_episode(%{actor_id: "drain_actor", status: :running})
    insert_step(%{episode_id: a.id, step_no: 1})
    insert_step(%{episode_id: a.id, step_no: 2})

    fake_task(a)
    fake_task(b)

    assert {:ok, 2} = EpisodeDrainer.drain_running()

    for ep <- [a, b] do
      reloaded = Episodes.get!(ep.id)
      assert reloaded.status == :running
      assert reloaded.phase == "interrupted"
    end

    assert [%{step_no: 1}, %{step_no: 2}, %{step_no: 3, kind: :observation, result_ref: ref_a}] =
             steps(a.id)

    assert ref_a["event"] == "interrupted"
    assert [%{step_no: 1, kind: :observation, result_ref: ref_b}] = steps(b.id)
    assert ref_b["event"] == "interrupted"

    # Each task was told, and each got its two broadcasts.
    assert_receive {:drained, a_id} when a_id == a.id
    assert_receive {:drained, b_id} when b_id == b.id

    for ep <- [a, b] do
      assert_receive {:bus, "episode.step_journaled", %{episode_id: id, kind: :observation}}
                     when id == ep.id

      assert_receive {:bus, "episode.interrupted", %{episode_id: id, phase: "interrupted"}}
                     when id == ep.id
    end
  end

  test "a task that already finished is not re-labelled" do
    done = insert_episode(%{actor_id: "drain_actor", status: :done})
    fake_task(done)

    assert {:ok, 1} = EpisodeDrainer.drain_running()
    assert Episodes.get!(done.id).phase == nil
  end

  test "nothing registered is a no-op" do
    assert {:ok, 0} = EpisodeDrainer.drain_running()
    assert {:ok, 0} = EpisodeDrainer.interrupt([])
  end

  test "interrupt/1 is the single-episode path the runner uses" do
    ep = insert_episode(%{actor_id: "drain_actor", status: :running})

    assert {:ok, 1} = EpisodeDrainer.interrupt([EpisodeDrainer.entry(ep)])
    assert Episodes.get!(ep.id).phase == "interrupted"
    assert [%{kind: :observation, result_ref: %{"event" => "interrupted"}}] = steps(ep.id)
    assert Repo.aggregate(EpisodeStep, :count) == 1
  end

  test "episode.interrupted names the run's subject" do
    trigger_ref = %{"payload" => %{"thing_id" => "t-1"}}

    ep =
      insert_episode(%{
        actor_id: "drain_actor",
        expectation_id: "appraise",
        trigger_ref: trigger_ref,
        status: :running
      })

    assert {:ok, 1} = EpisodeDrainer.interrupt([EpisodeDrainer.entry(ep)])

    assert_receive {:bus, "episode.interrupted", payload}
    assert payload.episode_id == ep.id
    assert payload.expectation_id == "appraise"
    assert payload.trigger_ref == trigger_ref
    assert Cyclium.Bus.subject(payload, "thing_id") == "t-1"
  end
end

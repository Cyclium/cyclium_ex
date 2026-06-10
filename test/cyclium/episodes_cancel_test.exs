defmodule Cyclium.EpisodesCancelTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    start_supervised!({Phoenix.PubSub, name: Cyclium.TestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TestPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
      Application.delete_env(:cyclium, :pubsub)
    end)

    # Insert a test episode into the FakeRepo
    episode = %Cyclium.Schemas.Episode{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      trigger_type: :schedule,
      status: :running,
      budget: %{"max_turns" => 10},
      turns_used: 0,
      tokens_used: 0,
      started_at: DateTime.utc_now()
    }

    # Manually insert into FakeRepo
    Agent.update(Cyclium.FakeRepo, fn state ->
      episode_with_id = %{episode | id: episode.id || Ecto.UUID.generate()}
      %{state | records: [episode_with_id | state.records]}
    end)

    %{episode: episode}
  end

  describe "cancel/2" do
    test "cancels an episode and emits telemetry", %{episode: episode} do
      ref = make_ref()

      :telemetry.attach(
        "test-cancel-#{inspect(ref)}",
        [:cyclium, :episode, :canceled],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      assert :ok = Cyclium.Episodes.cancel(episode.id, "test_reason")

      assert_receive {:telemetry, [:cyclium, :episode, :canceled], %{count: 1}, meta}
      assert meta.episode_id == episode.id
      assert meta.reason == "test_reason"

      :telemetry.detach("test-cancel-#{inspect(ref)}")
    end

    test "publishes Bus event", %{episode: episode} do
      Cyclium.Bus.subscribe("episode.canceled")

      Cyclium.Episodes.cancel(episode.id)

      assert_receive {:bus, "episode.canceled", payload}
      assert payload.episode_id == episode.id
    end
  end

  describe "request_cancel/2" do
    test "running episode broadcasts a cancel to the worker", %{episode: episode} do
      Cyclium.Bus.subscribe_cancel(episode.id)

      assert {:ok, :requested} = Cyclium.Episodes.request_cancel(episode.id, "stop_clicked")

      assert_receive {:cyclium_cancel, "stop_clicked"}
    end

    test "blocked episode is canceled directly", %{episode: episode} do
      {:ok, _} = Cyclium.Episodes.update_status(episode.id, :blocked)
      Cyclium.Bus.subscribe("episode.canceled")

      assert {:ok, :canceled} = Cyclium.Episodes.request_cancel(episode.id)

      assert_receive {:bus, "episode.canceled", %{episode_id: id}}
      assert id == episode.id
      assert Cyclium.Episodes.get!(episode.id).status == :canceled
    end

    test "terminal episode is a no-op", %{episode: episode} do
      {:ok, _} = Cyclium.Episodes.update_status(episode.id, :done)

      assert {:error, {:not_active, :done}} = Cyclium.Episodes.request_cancel(episode.id)
    end
  end
end

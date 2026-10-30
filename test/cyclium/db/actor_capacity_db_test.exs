defmodule Cyclium.ActorCapacityDbTest do
  @moduledoc """
  An actor reports its running and queued counts on each change, an episode
  that joins its queue is counted, and a queued episode's start measures how
  long it waited for a slot.
  """
  use Cyclium.DataCase

  alias Cyclium.{ActorCapacity, ConvergeResult, EpisodeRunner}

  defmodule QueueActor do
    use Cyclium.Actor

    actor do
      identifier(:capacity_queue_actor)
      domain(:testing)
      max_concurrent_episodes(1)
      episode_overflow(:queue)

      expectation(:do_work, trigger: {:event, "work.requested"})
    end
  end

  defmodule ShedActor do
    use Cyclium.Actor

    actor do
      identifier(:capacity_shed_actor)
      domain(:testing)
      max_concurrent_episodes(1)
      episode_overflow(:shed_oldest)

      expectation(:do_work, trigger: {:event, "work.requested"})
    end
  end

  defmodule DoneStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{}}
    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx),
      do: {:ok, %ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}
  end

  @events [
    [:cyclium, :actor, :capacity],
    [:cyclium, :actor, :queued],
    [:cyclium, :actor, :overflow],
    [:cyclium, :episode, :started],
    [:cyclium, :episode, :resumed]
  ]

  setup do
    ActorCapacity.ensure_table()
    start_supervised!({Phoenix.PubSub, name: Cyclium.ActorCapacityTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.ActorCapacityTestPubSub)

    unless Process.whereis(Cyclium.ActorProcessRegistry),
      do: start_supervised!({Registry, keys: :unique, name: Cyclium.ActorProcessRegistry})

    start_supervised!(Cyclium.FakeRunner)
    Cyclium.FakeRunner.reset()
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    test_pid = self()
    handler = "actor-capacity-test-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.delete_env(:cyclium, :runner)
      Application.delete_env(:cyclium, :pubsub)
    end)

    :ok
  end

  defp start_actor(module, name) do
    {:ok, pid} = module.start_link(name: name)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  test "an actor reports its counts as episodes run, queue and drain" do
    pid = start_actor(QueueActor, :capacity_queue_test)

    assert_receive {:telemetry, [:cyclium, :actor, :capacity],
                    %{active: 0, queued: 0, max_concurrent: 1},
                    %{actor_id: :capacity_queue_actor}}

    running = Ecto.UUID.generate()
    send(pid, {:recover_episode, running})

    assert_receive {:telemetry, [:cyclium, :actor, :capacity], %{active: 1, queued: 0}, _}

    send(pid, {:force_fire, :do_work})

    assert_receive {:telemetry, [:cyclium, :actor, :overflow], %{count: 1},
                    %{policy: :queue, expectation_id: "do_work"}},
                   1_000

    assert_receive {:telemetry, [:cyclium, :actor, :queued],
                    %{queue_depth: 1, active: 1, max_concurrent: 1}, %{episode_id: queued_id}}

    assert_receive {:telemetry, [:cyclium, :actor, :capacity], %{active: 1, queued: 1}, _}
    assert ActorCapacity.get(:capacity_queue_actor) == %{active: 1, queued: 1, max_concurrent: 1}

    send(pid, {:episode_completed, running})

    assert_receive {:telemetry, [:cyclium, :actor, :capacity], %{active: 1, queued: 0}, _}
    assert queued_id in Cyclium.FakeRunner.enqueued_episodes()
    assert %{"capacity_queue_actor" => %{active: 1, queued: 0}} = ActorCapacity.all()

    GenServer.stop(pid)
    assert ActorCapacity.get(:capacity_queue_actor) == nil
  end

  test "an unchanged count is not reported again" do
    pid = start_actor(QueueActor, :capacity_unchanged_test)
    assert_receive {:telemetry, [:cyclium, :actor, :capacity], %{active: 0}, _}

    send(pid, {:episode_completed, Ecto.UUID.generate()})
    :sys.get_state(pid)

    refute_receive {:telemetry, [:cyclium, :actor, :capacity], _, _}
    GenServer.stop(pid)
  end

  test "a recovered episode held at capacity is enqueued with its hold time" do
    pid = start_actor(QueueActor, :capacity_held_test)
    running = Ecto.UUID.generate()
    held = Ecto.UUID.generate()

    send(pid, {:recover_episode, running})
    send(pid, {:recover_episode, held})
    send(pid, {:episode_completed, running})
    :sys.get_state(pid)

    assert [resume: true, queued_at: held_at] =
             Cyclium.FakeRunner.enqueued_calls()
             |> Enum.find_value(fn {id, opts} -> if id == held, do: opts end)

    assert {:ok, _, _} = DateTime.from_iso8601(held_at)
    assert :sys.get_state(pid).recovery_held_at == %{}

    GenServer.stop(pid)
  end

  test "shedding reports the overflow with its policy" do
    pid = start_actor(ShedActor, :capacity_shed_test)
    send(pid, {:recover_episode, Ecto.UUID.generate()})
    send(pid, {:force_fire, :do_work})

    assert_receive {:telemetry, [:cyclium, :actor, :overflow], _, %{policy: :shed_oldest}},
                   1_000

    GenServer.stop(pid)
  end

  describe "episode start" do
    defp budget, do: %{"max_turns" => 5, "max_tokens" => 1_000, "max_wall_ms" => 10_000}

    test "a queued episode measures its wait and starts its started_at now" do
      queued_at = DateTime.add(DateTime.utc_now(), -5, :second)
      episode = insert_episode(%{budget: budget(), queued_at: queued_at, started_at: queued_at})
      id = episode.id
      Cyclium.Bus.subscribe("episode.started")

      assert {:ok, _} = EpisodeRunner.execute_loop(episode, DoneStrategy, %{})

      assert_receive {:telemetry, [:cyclium, :episode, :started], %{queue_wait_ms: wait},
                      %{episode_id: ^id}}

      assert wait >= 5_000
      assert_receive {:bus, "episode.started", %{episode_id: ^id, queued_at: ^queued_at}}

      stored = Repo.get!(Cyclium.Schemas.Episode, id)
      assert stored.queued_at == queued_at
      assert DateTime.diff(stored.started_at, queued_at, :millisecond) >= 5_000
    end

    test "an episode that already started once keeps its started_at and measures no wait" do
      queued_at = DateTime.add(DateTime.utc_now(), -60, :second)
      started_at = DateTime.add(queued_at, 10, :second)
      episode = insert_episode(%{budget: budget(), queued_at: queued_at, started_at: started_at})
      id = episode.id

      assert {:ok, _} = EpisodeRunner.execute_loop(episode, DoneStrategy, %{})

      assert_receive {:telemetry, [:cyclium, :episode, :started], measurements,
                      %{episode_id: ^id}}

      refute Map.has_key?(measurements, :queue_wait_ms)
      assert Repo.get!(Cyclium.Schemas.Episode, id).started_at == started_at
    end

    test "a recovered episode held at capacity measures its wait on resume" do
      started_at = DateTime.add(DateTime.utc_now(), -60, :second)
      held_at = DateTime.add(DateTime.utc_now(), -3, :second)
      episode = insert_episode(%{budget: budget(), started_at: started_at})
      id = episode.id

      assert {:ok, _} =
               EpisodeRunner.execute_loop(episode, DoneStrategy, %{},
                 resume: true,
                 queued_at: DateTime.to_iso8601(held_at)
               )

      assert_receive {:telemetry, [:cyclium, :episode, :resumed], %{queue_wait_ms: wait},
                      %{episode_id: ^id}}

      assert wait >= 3_000
      assert Repo.get!(Cyclium.Schemas.Episode, id).started_at == started_at
    end

    test "an episode that never queued measures no wait" do
      episode = insert_episode(%{budget: budget()})
      id = episode.id

      assert {:ok, _} = EpisodeRunner.execute_loop(episode, DoneStrategy, %{})

      assert_receive {:telemetry, [:cyclium, :episode, :started], measurements,
                      %{episode_id: ^id}}

      refute Map.has_key?(measurements, :queue_wait_ms)
    end
  end
end

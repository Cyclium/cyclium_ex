defmodule Cyclium.ReconcilerTest do
  use ExUnit.Case, async: false

  defmodule TestActor do
    use Cyclium.Actor

    actor do
      domain(:testing)
      capabilities([:read_test])
      max_concurrent_episodes(2)
      episode_overflow(:drop)

      expectation(:check_one,
        trigger: {:schedule, 5_000},
        description: "First check"
      )

      expectation(:check_two,
        trigger: {:event, "test.event"},
        description: "Second check"
      )
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.TestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TestPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
    end)

    :ok
  end

  describe "Reconciler GenServer" do
    test "starts and subscribes to spec.updated" do
      {:ok, pid} = Cyclium.Reconciler.start_link(name: :test_reconciler)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "Actor hot-reload via reconcile" do
    test "actor accepts reconcile cast without crashing" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_reconcile)

      state_before = :sys.get_state(pid)
      assert map_size(state_before.expectations) == 2

      # Send a reconcile with the same expectations — should be a no-op
      new_config = TestActor.__cyclium_config__()
      new_expectations = TestActor.__cyclium_expectations__()
      GenServer.cast(pid, {:reconcile, new_config, new_expectations})

      # Give it a moment to process
      :timer.sleep(10)

      state_after = :sys.get_state(pid)
      assert map_size(state_after.expectations) == 2

      GenServer.stop(pid)
    end

    test "reconcile updates config" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_reconfig)

      # Send reconcile with changed config
      new_config = %{TestActor.__cyclium_config__() | max_concurrent_episodes: 5}
      GenServer.cast(pid, {:reconcile, new_config, TestActor.__cyclium_expectations__()})

      :timer.sleep(10)

      state = :sys.get_state(pid)
      assert state.config.max_concurrent_episodes == 5

      GenServer.stop(pid)
    end

    test "reconcile removes timers for removed expectations" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_remove_timer)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.timers, :check_one)

      # Reconcile with only check_two (remove check_one)
      reduced_expectations = [
        {:check_two,
         [
           trigger: {:event, "test.event"},
           description: "Second check"
         ]}
      ]

      GenServer.cast(pid, {:reconcile, TestActor.__cyclium_config__(), reduced_expectations})
      :timer.sleep(10)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.timers, :check_one)
      refute Map.has_key?(state.expectations, :check_one)
      assert Map.has_key?(state.expectations, :check_two)

      GenServer.stop(pid)
    end

    test "reconcile adds timers for new schedule expectations" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_add_timer)

      # Add a new schedule expectation
      new_expectations =
        TestActor.__cyclium_expectations__() ++
          [
            {:check_three,
             [
               trigger: {:schedule, 10_000},
               description: "New check"
             ]}
          ]

      GenServer.cast(pid, {:reconcile, TestActor.__cyclium_config__(), new_expectations})
      :timer.sleep(10)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.expectations, :check_three)
      assert Map.has_key?(state.timers, :check_three)

      GenServer.stop(pid)
    end
  end
end

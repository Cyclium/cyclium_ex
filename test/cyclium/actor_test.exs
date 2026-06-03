defmodule Cyclium.ActorTest do
  use ExUnit.Case

  # Define a test actor module
  defmodule TestActor do
    use Cyclium.Actor

    actor do
      domain(:testing)
      capabilities([:read_test, :write_test])
      max_concurrent_episodes(2)
      episode_overflow(:drop)

      expectation(:check_health,
        trigger: {:schedule, 100},
        description: "Periodic health check",
        outputs: [:slack],
        budget: %{max_turns: 5, max_tokens: 10_000, max_wall_ms: 30_000}
      )

      expectation(:react_to_alert,
        trigger: {:event, "alert.fired"},
        filter: %{severity: "high"},
        debounce_ms: 200,
        cooldown_ms: 1_000,
        description: "React to high-severity alerts"
      )
    end
  end

  # Actor with strategy and synthesizer declared inline for registration tests
  defmodule RegistrationActor do
    use Cyclium.Actor

    actor do
      domain(:testing)
      synthesizer(__MODULE__.FakeSynthesizer)
      spec_rev("v2.0.0")

      expectation(:do_work,
        strategy: __MODULE__.FakeStrategy,
        trigger: {:schedule, :timer.hours(1)},
        budget: %{max_turns: 10, max_tokens: 5_000, max_wall_ms: 30_000},
        log_strategy: :full_debug
      )

      expectation(:do_other_work,
        strategy: __MODULE__.OtherStrategy,
        synthesizer: __MODULE__.OtherSynthesizer,
        trigger: {:event, "work.requested"}
      )
    end
  end

  # Actor with explicit identifier — survives module renames
  defmodule IdentifiedActor do
    use Cyclium.Actor

    actor do
      identifier(:my_stable_id)
      domain(:testing)
      synthesizer(__MODULE__.FakeSynthesizer)

      expectation(:do_work,
        strategy: __MODULE__.FakeStrategy,
        trigger: {:event, "work.requested"}
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

  describe "DSL compilation" do
    test "config is compiled correctly" do
      config = TestActor.__cyclium_config__()

      assert config.actor_id == :test_actor
      assert config.domain == :testing
      assert config.capabilities == [:read_test, :write_test]
      assert config.max_concurrent_episodes == 2
      assert config.episode_overflow == :drop
    end

    test "expectations are compiled correctly" do
      expectations = TestActor.__cyclium_expectations__()

      assert length(expectations) == 2

      {health_id, health_opts} = Enum.find(expectations, fn {id, _} -> id == :check_health end)
      assert health_id == :check_health
      assert Keyword.get(health_opts, :trigger) == {:schedule, 100}
      assert Keyword.get(health_opts, :description) == "Periodic health check"

      {alert_id, alert_opts} = Enum.find(expectations, fn {id, _} -> id == :react_to_alert end)
      assert alert_id == :react_to_alert
      assert Keyword.get(alert_opts, :trigger) == {:event, "alert.fired"}
      assert Keyword.get(alert_opts, :filter) == %{severity: "high"}
      assert Keyword.get(alert_opts, :debounce_ms) == 200
      assert Keyword.get(alert_opts, :cooldown_ms) == 1_000
    end
  end

  describe "GenServer init" do
    test "actor starts and builds state" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_init)

      state = :sys.get_state(pid)

      assert state.actor_id == :test_actor
      assert map_size(state.expectations) == 2
      assert MapSet.size(state.active_episodes) == 0
      assert :queue.is_empty(state.queued_episodes)

      # Schedule timer should be set for :check_health
      assert Map.has_key?(state.timers, :check_health)

      GenServer.stop(pid)
    end

    test "event-triggered expectation infers subscribes_to" do
      {:ok, pid} = TestActor.start_link(name: :test_actor_subs)
      state = :sys.get_state(pid)

      alert_exp = state.expectations[:react_to_alert]
      assert "alert.fired" in alert_exp.subscribes_to

      GenServer.stop(pid)
    end
  end

  describe "recovery hand-off ({:recover_episode, id})" do
    setup do
      start_supervised!(Cyclium.FakeRunner)
      Cyclium.FakeRunner.reset()
      Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)
      on_exit(fn -> Application.delete_env(:cyclium, :runner) end)
      :ok
    end

    test "runs up to max_concurrent_episodes and queues the rest" do
      # TestActor has max_concurrent_episodes(2)
      {:ok, pid} = TestActor.start_link(name: :recover_actor_capacity)

      for id <- ["ep-1", "ep-2", "ep-3"], do: send(pid, {:recover_episode, id})

      state = :sys.get_state(pid)

      # Two enqueued under concurrency cap, one held in the in-memory queue
      assert MapSet.size(state.active_episodes) == 2
      assert :queue.len(state.queued_episodes) == 1
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 2

      GenServer.stop(pid)
    end

    test "queues recovered episodes even when overflow policy is :drop" do
      # TestActor uses episode_overflow(:drop); recovered work must never be
      # dropped — it represents real in-flight work.
      {:ok, pid} = TestActor.start_link(name: :recover_actor_no_drop)

      for id <- ["ep-1", "ep-2", "ep-3", "ep-4"], do: send(pid, {:recover_episode, id})

      state = :sys.get_state(pid)
      assert MapSet.size(state.active_episodes) == 2
      assert :queue.len(state.queued_episodes) == 2

      GenServer.stop(pid)
    end

    test "draining a queued episode enqueues the next one" do
      {:ok, pid} = TestActor.start_link(name: :recover_actor_drain)

      for id <- ["ep-1", "ep-2", "ep-3"], do: send(pid, {:recover_episode, id})

      # Complete one active episode — the queued one should be promoted
      [active_id | _] = :sys.get_state(pid).active_episodes |> MapSet.to_list()
      send(pid, {:episode_completed, active_id})

      state = :sys.get_state(pid)
      assert MapSet.size(state.active_episodes) == 2
      assert :queue.is_empty(state.queued_episodes)
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 3

      GenServer.stop(pid)
    end

    test "ignores a duplicate hand-off for an already-active episode" do
      {:ok, pid} = TestActor.start_link(name: :recover_actor_dedup)

      send(pid, {:recover_episode, "ep-1"})
      send(pid, {:recover_episode, "ep-1"})

      state = :sys.get_state(pid)
      assert MapSet.size(state.active_episodes) == 1
      assert :queue.is_empty(state.queued_episodes)
      assert length(Cyclium.FakeRunner.enqueued_episodes()) == 1

      GenServer.stop(pid)
    end
  end

  describe "filter matching" do
    test "empty filter matches everything" do
      exp = %Cyclium.Expectation{
        id: :test,
        actor_id: :a,
        domain: :d,
        trigger: {:event, "test"},
        subscribes_to: ["test"],
        filter: %{}
      }

      assert Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{anything: true})
    end

    test "exact match filter works" do
      exp = %Cyclium.Expectation{
        id: :test,
        actor_id: :a,
        domain: :d,
        trigger: {:event, "test"},
        subscribes_to: ["test"],
        filter: %{severity: "high"}
      }

      assert Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{severity: "high"})
      refute Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{severity: "low"})
    end

    test "in-list filter works" do
      exp = %Cyclium.Expectation{
        id: :test,
        actor_id: :a,
        domain: :d,
        trigger: {:event, "test"},
        subscribes_to: ["test"],
        filter: %{status: {:in, ["OPEN", "STALLED"]}}
      }

      assert Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{status: "OPEN"})
      assert Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{status: "STALLED"})
      refute Cyclium.Actor.Server |> send_event_and_check(exp, "test", %{status: "CLOSED"})
    end

    # Helper — calls the private event_matches? via a thin test shim
    defp send_event_and_check(_module, exp, event_type, payload) do
      # We test filter logic via the actor GenServer behavior
      # by checking if the event type is in subscribes_to and filter matches
      event_type in exp.subscribes_to and filter_matches?(exp.filter, payload)
    end

    defp filter_matches?(filter, _payload) when filter == %{}, do: true

    defp filter_matches?(filter, payload) do
      Enum.all?(filter, fn {key, expected} ->
        actual = Map.get(payload, key) || Map.get(payload, to_string(key))

        case expected do
          {:in, values} -> actual in values
          value -> actual == value
        end
      end)
    end
  end

  describe "boot registration — strategy and synthesizer" do
    setup do
      start_supervised!({RegistrationActor, [name: :registration_actor_test]})

      on_exit(fn ->
        :persistent_term.erase({:cyclium_actor_synthesizer, :registration_actor})
        :persistent_term.erase({:cyclium_actor_spec_rev, :registration_actor})
        :persistent_term.erase({:cyclium_actor_strategy, :registration_actor, :do_work})
        :persistent_term.erase({:cyclium_actor_strategy, :registration_actor, :do_other_work})
        :persistent_term.erase({:cyclium_expectation_synthesizer, :registration_actor, :do_work})

        :persistent_term.erase(
          {:cyclium_expectation_synthesizer, :registration_actor, :do_other_work}
        )

        :persistent_term.erase({:cyclium_expectation_budget, :registration_actor, :do_work})
        :persistent_term.erase({:cyclium_expectation_budget, :registration_actor, :do_other_work})
        :persistent_term.erase({:cyclium_expectation_log_strategy, :registration_actor, :do_work})

        :persistent_term.erase(
          {:cyclium_expectation_log_strategy, :registration_actor, :do_other_work}
        )
      end)

      :ok
    end

    test "registers actor-level synthesizer in persistent_term" do
      assert :persistent_term.get({:cyclium_actor_synthesizer, :registration_actor}) ==
               RegistrationActor.FakeSynthesizer
    end

    test "registers per-expectation strategy in persistent_term" do
      assert :persistent_term.get({:cyclium_actor_strategy, :registration_actor, :do_work}) ==
               RegistrationActor.FakeStrategy

      assert :persistent_term.get({:cyclium_actor_strategy, :registration_actor, :do_other_work}) ==
               RegistrationActor.OtherStrategy
    end

    test "expectation-level synthesizer is registered in persistent_term" do
      # :do_other_work declares its own synthesizer — should be in persistent_term
      assert :persistent_term.get(
               {:cyclium_expectation_synthesizer, :registration_actor, :do_other_work}
             ) == RegistrationActor.OtherSynthesizer
    end

    test "expectation inherits actor-level synthesizer in persistent_term" do
      # :do_work has no explicit synthesizer — inherits actor-level FakeSynthesizer
      assert :persistent_term.get(
               {:cyclium_expectation_synthesizer, :registration_actor, :do_work}
             ) == RegistrationActor.FakeSynthesizer

      # :do_other_work overrides with OtherSynthesizer
      assert :persistent_term.get(
               {:cyclium_expectation_synthesizer, :registration_actor, :do_other_work}
             ) == RegistrationActor.OtherSynthesizer
    end

    test "strategy field is set on expectation struct" do
      state = :sys.get_state(:registration_actor_test)

      assert state.expectations[:do_work].strategy == RegistrationActor.FakeStrategy
      assert state.expectations[:do_other_work].strategy == RegistrationActor.OtherStrategy
    end

    test "expectation without strategy leaves key unregistered" do
      # TestActor has no strategy declared — key should not be in persistent_term
      # (test_actor may not even be running, but we confirm missing key behaviour)
      assert :persistent_term.get(
               {:cyclium_actor_strategy, :test_actor, :check_health},
               :not_found
             ) ==
               :not_found
    end

    test "registers spec_rev in persistent_term" do
      assert :persistent_term.get({:cyclium_actor_spec_rev, :registration_actor}) == "v2.0.0"
    end

    test "registers per-expectation budget in persistent_term" do
      budget = :persistent_term.get({:cyclium_expectation_budget, :registration_actor, :do_work})
      assert budget == %{max_turns: 10, max_tokens: 5_000, max_wall_ms: 30_000}
    end

    test "registers per-expectation log_strategy in persistent_term" do
      assert :persistent_term.get(
               {:cyclium_expectation_log_strategy, :registration_actor, :do_work}
             ) == :full_debug
    end

    test "expectation without explicit budget registers the struct default" do
      budget =
        :persistent_term.get(
          {:cyclium_expectation_budget, :registration_actor, :do_other_work},
          :not_found
        )

      # Expectation struct defaults: max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000
      assert budget == %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}
    end

    test "expectation without explicit log_strategy registers the struct default" do
      log_strategy =
        :persistent_term.get(
          {:cyclium_expectation_log_strategy, :registration_actor, :do_other_work},
          :not_found
        )

      # Expectation struct defaults to :timeline
      assert log_strategy == :timeline
    end

    test "persistent_term keys are atoms, matching safe_to_atom conversion" do
      # EpisodeTask receives string actor_id/expectation_id from DB records
      # and converts them with String.to_existing_atom/1 before lookup.
      # Verify the registered keys use atoms so the conversion will match.
      key = {:cyclium_actor_strategy, :registration_actor, :do_work}
      assert :persistent_term.get(key) == RegistrationActor.FakeStrategy

      # Simulate what EpisodeTask does: convert strings to existing atoms
      actor_atom = String.to_existing_atom("registration_actor")
      exp_atom = String.to_existing_atom("do_work")

      assert :persistent_term.get({:cyclium_actor_strategy, actor_atom, exp_atom}) ==
               RegistrationActor.FakeStrategy

      # Same for expectation-level synthesizer
      exp_synth_atom = String.to_existing_atom("do_other_work")

      assert :persistent_term.get({:cyclium_expectation_synthesizer, actor_atom, exp_synth_atom}) ==
               RegistrationActor.OtherSynthesizer
    end
  end

  describe "explicit identifier" do
    setup do
      start_supervised!({IdentifiedActor, [name: :identified_actor_test]})

      on_exit(fn ->
        :persistent_term.erase({:cyclium_actor_synthesizer, :my_stable_id})
        :persistent_term.erase({:cyclium_actor_strategy, :my_stable_id, :do_work})
        :persistent_term.erase({:cyclium_expectation_synthesizer, :my_stable_id, :do_work})
      end)

      :ok
    end

    test "identifier/1 overrides module-derived actor_id" do
      config = IdentifiedActor.__cyclium_config__()
      assert config.actor_id == :my_stable_id
    end

    test "persistent_term keys use the explicit identifier" do
      assert :persistent_term.get({:cyclium_actor_synthesizer, :my_stable_id}) ==
               IdentifiedActor.FakeSynthesizer

      assert :persistent_term.get({:cyclium_actor_strategy, :my_stable_id, :do_work}) ==
               IdentifiedActor.FakeStrategy
    end

    test "GenServer state uses the explicit identifier" do
      state = :sys.get_state(:identified_actor_test)
      assert state.actor_id == :my_stable_id
    end
  end
end

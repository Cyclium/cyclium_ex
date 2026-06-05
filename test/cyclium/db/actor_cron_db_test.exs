defmodule Cyclium.ActorCronDbTest do
  @moduledoc """
  Covers the native `{:cron, spec}` trigger: boot validation, timer arming, and
  the tick-precision dedupe key that gives at-most-once-per-occurrence across
  nodes (every node computes the same tick → same dedupe_key → the prod unique
  index lets exactly one episode through).
  """
  use Cyclium.DataCase

  import Ecto.Query
  alias Cyclium.Schemas.Episode

  defmodule CronActor do
    use Cyclium.Actor

    actor do
      identifier(:cron_test_actor)
      domain(:testing)
      expectation(:nightly, trigger: {:cron, "0 5 * * *"})
    end
  end

  defmodule BadCronActor do
    use Cyclium.Actor

    actor do
      identifier(:bad_cron_actor)
      # Four fields — invalid; must fail fast at boot.
      expectation(:broken, trigger: {:cron, "0 5 * *"})
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.CronTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.CronTestPubSub)
    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
    end)

    :ok
  end

  test "a cron trigger stores the spec and arms a timer" do
    pid = start_supervised!({CronActor, [name: :cron_test_actor]})
    state = :sys.get_state(pid)

    assert state.expectations[:nightly].trigger == {:cron, "0 5 * * *"}
    assert Map.has_key?(state.timers, :nightly)
  end

  test "an invalid cron spec fails the actor at boot" do
    Process.flag(:trap_exit, true)
    assert {:error, _} = start_supervised({BadCronActor, [name: :bad_cron_actor]})
  end

  test "a cron fire creates an episode keyed by the exact tick" do
    pid = start_supervised!({CronActor, [name: :cron_test_actor]})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    tick = ~U[2026-06-05 05:00:00Z]
    send(pid, {:cron_fire, :nightly, tick})
    # Synchronous system call — returns only after the {:cron_fire, ...} message
    # ahead of it in the mailbox has been fully handled.
    :sys.get_state(pid)

    episodes = Repo.all(from(e in Episode, where: e.actor_id == "cron_test_actor"))

    assert [episode] = episodes
    assert episode.trigger_type == :schedule
    assert episode.dedupe_key == "schedule:cron_test_actor:nightly:2026-06-05T05:00:00Z"
  end
end

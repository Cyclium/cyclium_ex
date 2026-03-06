defmodule Cyclium.ForceFireDbTest do
  @moduledoc """
  Integration tests for Episodes.force_fire/3 resolving spec_rev, budget,
  and log_strategy from persistent_term when not explicitly provided.
  """
  use Cyclium.DataCase

  alias Cyclium.Episodes
  alias Cyclium.Schemas.Episode

  # Define a test actor with known spec_rev, budget, and log_strategy
  defmodule FireTestActor do
    use Cyclium.Actor

    actor do
      identifier(:fire_test_actor)
      domain(:testing)
      spec_rev("v3.1.0")

      expectation(:check_stuff,
        trigger: {:event, "test.fire"},
        budget: %{max_turns: 7, max_tokens: 12_000, max_wall_ms: 60_000},
        log_strategy: :timeline
      )

      expectation(:no_budget_exp,
        trigger: {:event, "test.fire2"}
      )
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.ForceFireTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.ForceFireTestPubSub)

    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)

    start_supervised!({FireTestActor, [name: :fire_test_actor]})

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :runner)
      :persistent_term.erase({:cyclium_actor_spec_rev, :fire_test_actor})
      :persistent_term.erase({:cyclium_expectation_budget, :fire_test_actor, :check_stuff})
      :persistent_term.erase({:cyclium_expectation_budget, :fire_test_actor, :no_budget_exp})
      :persistent_term.erase({:cyclium_expectation_log_strategy, :fire_test_actor, :check_stuff})

      :persistent_term.erase(
        {:cyclium_expectation_log_strategy, :fire_test_actor, :no_budget_exp}
      )
    end)

    :ok
  end

  describe "force_fire resolves actor metadata" do
    test "resolves spec_rev from persistent_term" do
      {:ok, episode} = Episodes.force_fire("fire_test_actor", "check_stuff")

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.spec_rev == "v3.1.0"
    end

    test "resolves budget from persistent_term" do
      {:ok, episode} = Episodes.force_fire("fire_test_actor", "check_stuff")

      fetched = Repo.get!(Episode, episode.id)

      assert fetched.budget == %{
               "max_turns" => 7,
               "max_tokens" => 12_000,
               "max_wall_ms" => 60_000
             }
    end

    test "resolves log_strategy from persistent_term" do
      {:ok, episode} = Episodes.force_fire("fire_test_actor", "check_stuff")

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.log_strategy == "timeline"
    end

    test "explicit opts override persistent_term values" do
      {:ok, episode} =
        Episodes.force_fire("fire_test_actor", "check_stuff",
          spec_rev: "override-rev",
          budget: %{max_turns: 1},
          log_strategy: :none
        )

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.spec_rev == "override-rev"
      assert fetched.budget == %{"max_turns" => 1}
      assert fetched.log_strategy == "none"
    end

    test "uses struct defaults for expectation without explicit budget or log_strategy" do
      {:ok, episode} = Episodes.force_fire("fire_test_actor", "no_budget_exp")

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.spec_rev == "v3.1.0"
      # Expectation struct defaults
      assert fetched.budget == %{
               "max_turns" => 12,
               "max_tokens" => 25_000,
               "max_wall_ms" => 120_000
             }

      assert fetched.log_strategy == "timeline"
    end

    test "works with atom actor_id" do
      {:ok, episode} = Episodes.force_fire(:fire_test_actor, :check_stuff)

      fetched = Repo.get!(Episode, episode.id)
      assert fetched.spec_rev == "v3.1.0"

      assert fetched.budget == %{
               "max_turns" => 7,
               "max_tokens" => 12_000,
               "max_wall_ms" => 60_000
             }
    end
  end
end

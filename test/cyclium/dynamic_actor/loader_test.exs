defmodule Cyclium.DynamicActor.LoaderTest do
  use ExUnit.Case, async: false

  alias Cyclium.DynamicActor.Loader

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
    Loader.ensure_cache_table()

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)

      try do
        :ets.delete_all_objects(:cyclium_strategy_cache)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "strategy_for/1 — ETS cache" do
    test "returns nil for unknown actor (no DB record, no cache)" do
      assert Loader.strategy_for("nonexistent") == nil
    end

    test "returns cached strategy module when present in ETS" do
      :ets.insert(:cyclium_strategy_cache, {"cached_actor", SomeFakeModule})
      assert Loader.strategy_for("cached_actor") == SomeFakeModule
    end

    test "falls back to DB on cache miss (FakeRepo returns nil)" do
      # FakeRepo.one/1 always returns nil, so strategy_for returns nil
      assert Loader.strategy_for("uncached_actor") == nil
    end

    test "cache is cleared by invalidate via stop/1" do
      :ets.insert(:cyclium_strategy_cache, {"actor_to_stop", SomeFakeModule})
      assert :ets.lookup(:cyclium_strategy_cache, "actor_to_stop") != []

      # stop will invalidate cache (process won't be found, but cache is cleared)
      Loader.stop("actor_to_stop")

      assert :ets.lookup(:cyclium_strategy_cache, "actor_to_stop") == []
    end

    test "ensure_cache_table is idempotent" do
      # Table already exists from setup
      assert Loader.ensure_cache_table() == :cyclium_strategy_cache

      # Insert something, call again, data persists
      :ets.insert(:cyclium_strategy_cache, {"test_key", :value})
      Loader.ensure_cache_table()
      assert :ets.lookup(:cyclium_strategy_cache, "test_key") == [{"test_key", :value}]
    end
  end

  describe "process_name/1" do
    test "returns atom with cyclium_dynamic_ prefix" do
      assert Loader.process_name("my_actor") == :cyclium_dynamic_my_actor
    end
  end
end

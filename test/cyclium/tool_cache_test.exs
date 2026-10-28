defmodule Cyclium.ToolCacheTest do
  use ExUnit.Case, async: false

  alias Cyclium.{ToolCache, ToolExec}

  # Counts its calls so a test can tell a cached result from a fresh one.
  defmodule CountingTool do
    use Cyclium.Tool

    @impl true
    def cache_ttl, do: 30

    @impl true
    def call(:lookup, args, _ctx) do
      n = :counters.get(counter(), 1) + 1
      :counters.put(counter(), 1, n)
      {:ok, %{call: n, id: args["id"]}}
    end

    def call(:fail, _args, _ctx) do
      :counters.add(counter(), 1, 1)
      {:error, :not_found}
    end

    def counter, do: :persistent_term.get({__MODULE__, :counter})
  end

  defmodule ScopedTool do
    use Cyclium.Tool

    @impl true
    def cache_ttl, do: 30

    # Only the id decides the result.
    @impl true
    def cache_scope(args), do: "id:#{args["id"]}"

    @impl true
    def call(:lookup, _args, _ctx) do
      :counters.add(CountingTool.counter(), 1, 1)
      {:ok, :counters.get(CountingTool.counter(), 1)}
    end
  end

  defmodule WriteTool do
    use Cyclium.Tool

    @impl true
    def cache_ttl, do: 30

    @impl true
    def side_effect?, do: true

    @impl true
    def call(:update, _args, _ctx) do
      :counters.add(CountingTool.counter(), 1, 1)
      {:ok, :counters.get(CountingTool.counter(), 1)}
    end
  end

  defmodule UncachedTool do
    use Cyclium.Tool

    @impl true
    def call(:lookup, _args, _ctx) do
      :counters.add(CountingTool.counter(), 1, 1)
      {:ok, :counters.get(CountingTool.counter(), 1)}
    end
  end

  setup do
    :persistent_term.put({CountingTool, :counter}, :counters.new(1, []))
    ToolCache.ensure_table()
    :ets.delete_all_objects(:cyclium_tool_cache)

    Application.put_env(:cyclium, :capability_registry, %{
      counting: CountingTool,
      scoped: ScopedTool,
      writer: WriteTool,
      uncached: UncachedTool
    })

    on_exit(fn -> Application.delete_env(:cyclium, :capability_registry) end)
    :ok
  end

  defp ctx(conv_id \\ "conv-1", episode_id \\ "ep-1") do
    %{
      episode: %Cyclium.Schemas.Episode{
        id: episode_id,
        actor_id: "tool_cache_test_actor",
        conversation_id: conv_id
      }
    }
  end

  defp calls, do: :counters.get(CountingTool.counter(), 1)

  describe "ToolExec with a cache_ttl" do
    test "a repeated call in the conversation reuses the result and says so" do
      assert {:ok, %{call: 1}, 0, first} = ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx())
      refute first[:cached]

      assert {:ok, %{call: 1}, 0, second} = ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx())
      assert second.cached
      assert second.result_redacted == %{call: 1, id: 1}
      assert calls() == 1
    end

    test "different args are different entries by default" do
      ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx())

      assert {:ok, %{call: 2, id: 2}, _, _} =
               ToolExec.call(:counting, :lookup, %{"id" => 2}, ctx())
    end

    test "framework-internal args do not split the key" do
      ToolExec.call(:counting, :lookup, %{"id" => 1, "_session_pid" => self()}, ctx())

      ToolExec.call(
        :counting,
        :lookup,
        %{"id" => 1, "_session_pid" => spawn(fn -> :ok end)},
        ctx()
      )

      assert calls() == 1
    end

    test "another conversation never sees the entry" do
      ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx("conv-1"))

      assert {:ok, %{call: 2}, _, _} =
               ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx("conv-2"))
    end

    test "outside a conversation the episode is the scope" do
      ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx(nil, "ep-1"))
      ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx(nil, "ep-1"))
      assert calls() == 1

      ToolExec.call(:counting, :lookup, %{"id" => 1}, ctx(nil, "ep-2"))
      assert calls() == 2
    end

    test "a cache_scope override decides which args share a result" do
      ToolExec.call(:scoped, :lookup, %{"id" => 1, "page" => 1}, ctx())

      assert {:ok, 1, _, %{cached: true}} =
               ToolExec.call(:scoped, :lookup, %{"id" => 1, "page" => 2}, ctx())
    end

    test "errors are not cached" do
      ToolExec.call(:counting, :fail, %{}, ctx())
      ToolExec.call(:counting, :fail, %{}, ctx())
      assert calls() == 2
    end

    test "a tool that declares side effects is never cached" do
      ToolExec.call(:writer, :update, %{}, ctx())
      ToolExec.call(:writer, :update, %{}, ctx())
      assert calls() == 2
    end

    test "a tool without a cache_ttl calls through every time" do
      ToolExec.call(:uncached, :lookup, %{}, ctx())
      assert {:ok, 2, 0, redacted} = ToolExec.call(:uncached, :lookup, %{}, ctx())
      refute Map.has_key?(redacted, :cached)
    end
  end

  describe "ToolCache" do
    test "an entry past its TTL misses and is removed" do
      key = {"conv-1", :t, :a, ""}
      :ets.insert(:cyclium_tool_cache, {key, :stale, System.monotonic_time(:millisecond) - 1})

      assert ToolCache.fetch(key) == :miss
      assert :ets.lookup(:cyclium_tool_cache, key) == []
    end

    test "purge/1 drops one scope's entries" do
      ToolCache.put({"conv-1", :t, :a, "x"}, 1, 30)
      ToolCache.put({"conv-2", :t, :a, "x"}, 2, 30)

      ToolCache.purge("conv-1")

      assert ToolCache.fetch({"conv-1", :t, :a, "x"}) == :miss
      assert ToolCache.fetch({"conv-2", :t, :a, "x"}) == {:hit, 2}
    end

    test "sweep/0 drops only expired entries" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(:cyclium_tool_cache, {{"c", :t, :a, "old"}, 1, now - 1})
      ToolCache.put({"c", :t, :a, "new"}, 2, 30)

      assert ToolCache.sweep() == 1
      assert ToolCache.fetch({"c", :t, :a, "new"}) == {:hit, 2}
    end

    test "the sweeper process sweeps on its interval" do
      :ets.insert(
        :cyclium_tool_cache,
        {{"c", :t, :a, "old"}, 1, System.monotonic_time(:millisecond) - 1}
      )

      pid = start_supervised!({ToolCache, sweep_interval_ms: 10})

      Process.sleep(40)
      assert Process.alive?(pid)
      assert :ets.lookup(:cyclium_tool_cache, {"c", :t, :a, "old"}) == []
    end
  end
end

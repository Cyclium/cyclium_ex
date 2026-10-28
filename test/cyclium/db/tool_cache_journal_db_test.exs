defmodule Cyclium.ToolCacheJournalDbTest do
  @moduledoc "A cached tool result is still journaled as a tool call, marked as a cache hit."
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, Episodes, EpisodeRunner}

  defmodule CachedTool do
    use Cyclium.Tool

    @impl true
    def cache_ttl, do: 30

    @impl true
    def call(:read, _args, _ctx), do: {:ok, %{value: System.unique_integer()}}
  end

  defmodule TwiceStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{calls: 0}}

    def next_step(%{calls: n}, _ctx) when n < 2, do: {:tool_call, :cached, :read, %{"id" => 1}}
    def next_step(_state, _ctx), do: :converge

    def handle_result(state, _step, _result), do: {:ok, %{state | calls: state.calls + 1}}

    def converge(_state, _ctx),
      do: {:ok, %ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}
  end

  setup do
    Cyclium.ToolCache.ensure_table()
    Application.put_env(:cyclium, :capability_registry, %{cached: CachedTool})
    on_exit(fn -> Application.delete_env(:cyclium, :capability_registry) end)
    :ok
  end

  test "the second call is journaled with cache_hit and the same result" do
    episode =
      insert_episode(%{
        actor_id: "tool_cache_journal_actor",
        conversation_id: Ecto.UUID.generate(),
        budget: %{"max_turns" => 10, "max_tokens" => 1_000, "max_wall_ms" => 10_000},
        log_strategy: "full_debug"
      })

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, TwiceStrategy, %{calls: 0})

    assert [first, second] =
             episode.id |> Episodes.list_steps() |> Enum.filter(&(&1.kind == :tool_call))

    assert first.metadata == nil
    assert second.metadata == %{"cache_hit" => true}
    assert first.result_ref == second.result_ref
  end
end

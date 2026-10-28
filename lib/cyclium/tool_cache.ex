defmodule Cyclium.ToolCache do
  @moduledoc """
  Per-node cache of read-only tool results, used by `Cyclium.ToolExec` for a
  tool that declares a `cache_ttl/0`.

  An entry is keyed by `{scope, capability, action, tool.cache_scope(args)}`,
  where `scope` is the episode's conversation (or the episode itself when it has
  none), so a result is never shared across conversations. Only successful
  results are stored, and never for a tool whose `side_effect?/0` is true.

  Entries go three ways: a read past the TTL misses and deletes the entry;
  `purge/1` drops a scope's entries when its conversation resolves, is
  abandoned or times out; and this process sweeps expired entries every
  `sweep_interval_ms` (default 60s) for scopes that never end cleanly.

  Ages are measured on the monotonic clock. The table lives on one node, so a
  conversation whose turns run on different nodes misses rather than shares.
  A short TTL (30–60 seconds) keeps a turn's repeated reads cheap without
  serving data much older than the turn.
  """

  use GenServer

  @table :cyclium_tool_cache
  @default_sweep_ms 60_000

  @doc "Create the table if it does not exist. `Cyclium.Supervisor` calls this."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ref ->
        @table
    end
  end

  @doc """
  A fresh entry for `key`, or `:miss`. With no table (Cyclium.Supervisor not
  started) every lookup misses.
  """
  @spec fetch(term()) :: {:hit, term()} | :miss
  def fetch(key) do
    with true <- table?(),
         [{^key, result, expires_at}] <- :ets.lookup(@table, key) do
      if now() < expires_at do
        {:hit, result}
      else
        :ets.delete(@table, key)
        :miss
      end
    else
      _ -> :miss
    end
  end

  @doc "Store `result` under `key` for `ttl_seconds`. A no-op with no table."
  @spec put(term(), term(), pos_integer()) :: :ok
  def put(key, result, ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    if table?(), do: :ets.insert(@table, {key, result, now() + ttl_seconds * 1_000})
    :ok
  end

  @doc "Drop every entry for a conversation (or episode) scope."
  @spec purge(term()) :: :ok
  def purge(scope) do
    if table?(), do: :ets.match_delete(@table, {{scope, :_, :_, :_}, :_, :_})
    :ok
  end

  @doc "Drop every expired entry. Returns how many were dropped."
  @spec sweep() :: non_neg_integer()
  def sweep do
    if table?() do
      now = now()
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    else
      0
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    ensure_table()
    interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_ms)
    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp table?, do: :ets.whereis(@table) != :undefined

  defp now, do: System.monotonic_time(:millisecond)
end

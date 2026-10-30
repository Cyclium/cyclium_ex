defmodule Cyclium.ActorCapacity do
  @moduledoc """
  Each actor's episode slots on this node: how many episodes run, how many wait
  in its queue, and its `max_concurrent_episodes`.

  An actor writes its counts whenever they change and emits
  `[:cyclium, :actor, :capacity]` with them, so a reader never has to call the
  actor, which may be busy firing. The counts are per node: an actor that runs
  on three nodes has three sets, each with its own queue and its own
  `max_concurrent_episodes` slots.
  """

  @table :cyclium_actor_capacity

  @type counts :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          max_concurrent: pos_integer()
        }

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
  Store the actor server `state`'s counts and emit `[:cyclium, :actor, :capacity]`
  when they differ from the last stored ones. Returns `state`. A no-op with no
  table (`Cyclium.Supervisor` not started).
  """
  @spec record(map()) :: map()
  def record(%{actor_id: actor_id} = state) do
    key = to_string(actor_id)
    counts = counts(state)

    if table?() and stored(key) != counts do
      :ets.insert(@table, {key, counts})

      :telemetry.execute([:cyclium, :actor, :capacity], counts, %{
        actor_id: actor_id,
        node: node()
      })
    end

    state
  end

  @doc "The counts the actor last recorded on this node, or `nil` when it is not running here."
  @spec get(String.t() | atom()) :: counts() | nil
  def get(actor_id) do
    key = to_string(actor_id)
    if table?() and running_here?(key), do: stored(key)
  end

  @doc "Every actor running on this node, by actor id, with the counts it last recorded."
  @spec all() :: %{String.t() => counts()}
  def all do
    if table?() do
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {key, _counts} -> running_here?(key) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp counts(state) do
    %{
      active: MapSet.size(state.active_episodes),
      queued: :queue.len(state.queued_episodes),
      max_concurrent: state.config.max_concurrent_episodes
    }
  end

  defp stored(key) do
    case :ets.lookup(@table, key) do
      [{^key, counts}] -> counts
      [] -> nil
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  # An actor that stopped leaves its last counts behind; the process registry
  # says whether it still runs here. The registry drops a stopped process
  # asynchronously, so the registered pid is checked too. Without the registry,
  # every entry counts.
  defp running_here?(key) do
    registry = Cyclium.Actor.Server.actor_process_registry()

    case Process.whereis(registry) do
      nil -> true
      _pid -> Enum.any?(Registry.lookup(registry, key), fn {pid, _} -> Process.alive?(pid) end)
    end
  end
end

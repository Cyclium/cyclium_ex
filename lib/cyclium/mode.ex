defmodule Cyclium.Mode do
  @moduledoc """
  Runtime mode management for cyclium nodes.

  Controls whether episodes execute locally (`:full`) or are deferred to
  a trigger request table for another node to pick up (`:trigger_only`).

  Supports both node-wide mode and per-actor overrides, switchable at
  runtime without restart.

  ## Node-wide mode

      Cyclium.Mode.set(:trigger_only)
      Cyclium.Mode.set(:full)

  ## Per-actor overrides

      Cyclium.Mode.set_actor_override(:client_health, :trigger_only)
      Cyclium.Mode.clear_actor_override(:client_health)
      Cyclium.Mode.clear_all_overrides()

  ## Querying

      Cyclium.Mode.current()                      # node-wide mode
      Cyclium.Mode.effective(:client_health)       # per-actor, falls back to node
      Cyclium.Mode.runner_for(:client_health)      # resolved runner module
      Cyclium.Mode.overrides()                     # all active overrides

  Reads are ETS-backed for zero-cost lookups in hot paths (actor event handling).
  """

  use GenServer

  require Logger

  @table :cyclium_mode
  @node_key :__node_mode__

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the node-wide mode."
  @spec current() :: :full | :trigger_only | :disabled
  def current do
    case ets_lookup(@node_key) do
      nil -> default_mode()
      mode -> mode
    end
  end

  @doc "Returns the effective mode for a specific actor (override or node-wide)."
  @spec effective(atom()) :: :full | :trigger_only | :disabled
  def effective(actor_id) do
    case ets_lookup({:actor, actor_id}) do
      nil -> current()
      mode -> mode
    end
  end

  @doc "Returns the runner module for the given actor based on effective mode."
  @spec runner_for(atom() | String.t()) :: module()
  def runner_for(actor_id) do
    # Explicit runner config takes precedence (used in tests, backward compat)
    case Application.get_env(:cyclium, :runner) do
      nil ->
        actor_id = if is_binary(actor_id), do: safe_to_atom(actor_id), else: actor_id

        case effective(actor_id) do
          :full -> Cyclium.Runner.OTP
          :trigger_only -> Cyclium.Runner.Deferred
          :disabled -> Cyclium.Runner.Deferred
        end

      runner ->
        runner
    end
  end

  @doc "Returns the default runner based on node-wide mode (for non-actor contexts)."
  @spec default_runner() :: module()
  def default_runner do
    case Application.get_env(:cyclium, :runner) do
      nil ->
        case current() do
          :full -> Cyclium.Runner.OTP
          _ -> Cyclium.Runner.Deferred
        end

      runner ->
        runner
    end
  end

  @doc "Sets the node-wide mode at runtime."
  @spec set(:full | :trigger_only | :disabled) :: :ok
  def set(mode) when mode in [:full, :trigger_only, :disabled] do
    GenServer.call(__MODULE__, {:set_mode, mode})
  end

  @doc "Sets a mode override for a specific actor."
  @spec set_actor_override(atom(), :full | :trigger_only) :: :ok
  def set_actor_override(actor_id, mode) when mode in [:full, :trigger_only] do
    GenServer.call(__MODULE__, {:set_actor_override, actor_id, mode})
  end

  @doc "Clears a per-actor override, falling back to node-wide mode."
  @spec clear_actor_override(atom()) :: :ok
  def clear_actor_override(actor_id) do
    GenServer.call(__MODULE__, {:clear_actor_override, actor_id})
  end

  @doc "Clears all per-actor overrides."
  @spec clear_all_overrides() :: :ok
  def clear_all_overrides do
    GenServer.call(__MODULE__, :clear_all_overrides)
  end

  @doc "Returns all active per-actor overrides."
  @spec overrides() :: %{atom() => :full | :trigger_only}
  def overrides do
    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn
        {{:actor, actor_id}, mode}, acc -> Map.put(acc, actor_id, mode)
        _, acc -> acc
      end)
    else
      %{}
    end
  end

  @doc "Returns a summary of the current mode state."
  @spec status() :: map()
  def status do
    %{
      node_mode: current(),
      overrides: overrides(),
      node_identity: Cyclium.NodeIdentity.name()
    }
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])

    mode = default_mode()
    :ets.insert(table, {@node_key, mode})

    Logger.info("Cyclium.Mode initialized: #{mode}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) do
    old = current()
    :ets.insert(@table, {@node_key, mode})
    Logger.info("Cyclium.Mode: node mode changed #{old} -> #{mode}")
    {:reply, :ok, state}
  end

  def handle_call({:set_actor_override, actor_id, mode}, _from, state) do
    :ets.insert(@table, {{:actor, actor_id}, mode})
    Logger.info("Cyclium.Mode: actor override #{actor_id} -> #{mode}")
    {:reply, :ok, state}
  end

  def handle_call({:clear_actor_override, actor_id}, _from, state) do
    :ets.delete(@table, {:actor, actor_id})
    Logger.info("Cyclium.Mode: cleared override for #{actor_id}")
    {:reply, :ok, state}
  end

  def handle_call(:clear_all_overrides, _from, state) do
    # Delete all {:actor, _} keys, keep the node key
    :ets.match_delete(@table, {{:actor, :_}, :_})
    Logger.info("Cyclium.Mode: cleared all actor overrides")
    {:reply, :ok, state}
  end

  # -- Private --

  defp default_mode do
    Application.get_env(:cyclium, :mode, :full)
  end

  defp ets_lookup(key) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    else
      nil
    end
  end

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end

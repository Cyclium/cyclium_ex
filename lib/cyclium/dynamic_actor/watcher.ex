defmodule Cyclium.DynamicActor.Watcher do
  @moduledoc """
  Optional GenServer that subscribes to Bus events and automatically
  refreshes dynamic actors when their DB definitions change.

  ## Events handled

  - `"agent_definition.created"` — loads and starts a new dynamic actor
  - `"agent_definition.updated"` — drains, then reloads the actor from DB
  - `"agent_definition.disabled"` — drains and stops the actor

  ## Usage

  Add to your supervision tree if you want automatic refresh:

      children = [
        # ... other children ...
        Cyclium.DynamicActor.Watcher
      ]

  Then broadcast events from your application when definitions change:

      # After creating a new agent definition:
      Cyclium.Bus.broadcast("agent_definition.created", %{actor_id: "my_monitor"})

      # After updating an existing definition:
      Cyclium.Bus.broadcast("agent_definition.updated", %{actor_id: "my_monitor"})

      # After disabling a definition:
      Cyclium.Bus.broadcast("agent_definition.disabled", %{actor_id: "my_monitor"})

  If you don't want automatic refresh, call `Cyclium.DynamicActor.Lifecycle`
  functions directly instead.
  """

  use GenServer

  require Logger

  alias Cyclium.DynamicActor.{Lifecycle, Loader}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cyclium.Bus.subscribe()
    Logger.info("[Cyclium.DynamicActor.Watcher] Started, listening for agent definition events")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:bus, "agent_definition.created", %{actor_id: actor_id}}, state) do
    handle_created(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info({:bus, "agent_definition.created", %{"actor_id" => actor_id}}, state) do
    handle_created(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info({:bus, "agent_definition.updated", %{actor_id: actor_id}}, state) do
    handle_updated(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info({:bus, "agent_definition.updated", %{"actor_id" => actor_id}}, state) do
    handle_updated(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info({:bus, "agent_definition.disabled", %{actor_id: actor_id}}, state) do
    handle_disabled(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info({:bus, "agent_definition.disabled", %{"actor_id" => actor_id}}, state) do
    handle_disabled(to_string(actor_id))
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp handle_created(actor_id) do
    Logger.info("[Watcher] Loading new dynamic actor: #{actor_id}")

    case Loader.load(actor_id) do
      {:ok, _pid} ->
        Logger.info("[Watcher] Started dynamic actor: #{actor_id}")

      {:error, reason} ->
        Logger.error("[Watcher] Failed to start #{actor_id}: #{inspect(reason)}")
    end
  end

  defp handle_updated(actor_id) do
    Logger.info("[Watcher] Reloading dynamic actor: #{actor_id}")

    Task.start(fn ->
      case Lifecycle.drain_and_reload(actor_id) do
        {:ok, _pid} ->
          Logger.info("[Watcher] Reloaded dynamic actor: #{actor_id}")

        {:error, reason} ->
          Logger.error("[Watcher] Failed to reload #{actor_id}: #{inspect(reason)}")
      end
    end)
  end

  defp handle_disabled(actor_id) do
    Logger.info("[Watcher] Stopping dynamic actor: #{actor_id}")

    Task.start(fn ->
      case Lifecycle.drain_and_stop(actor_id) do
        :ok ->
          Logger.info("[Watcher] Stopped dynamic actor: #{actor_id}")

        {:error, reason} ->
          Logger.warning("[Watcher] Could not stop #{actor_id}: #{inspect(reason)}")
      end
    end)
  end
end

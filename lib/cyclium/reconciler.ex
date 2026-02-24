defmodule Cyclium.Reconciler do
  @moduledoc """
  Detects spec changes and reconciles running actors.

  Subscribes to `"spec.updated"` Bus events. When an actor's config
  or expectations change:

  1. Computes new config from the actor module
  2. Sends `{:reconcile, new_config, new_expectations}` to the actor GenServer
  3. Identifies orphaned blocked episodes (expectation removed) and cancels them

  ## Starting

  Added to `Cyclium.Supervisor` when reconciliation is enabled:

      config :cyclium, reconciler: true
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Cyclium.Bus.subscribe("spec.updated")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:bus, "spec.updated", %{actor_module: module} = payload}, state) do
    reconcile_actor(module, payload)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @doc """
  Trigger reconciliation for an actor module. Can be called programmatically
  or via the Bus event.
  """
  def reconcile_actor(module, _payload \\ %{}) do
    new_config = module.__cyclium_config__()
    new_expectations = module.__cyclium_expectations__()

    # Send reconcile message to the actor GenServer
    actor_name = module

    try do
      GenServer.cast(actor_name, {:reconcile, new_config, new_expectations})
    catch
      :exit, _ ->
        Logger.warning(
          "[Cyclium.Reconciler] Actor #{inspect(module)} not running, skipping reconcile"
        )
    end

    # Orphan cleanup: find blocked episodes for removed expectations
    cleanup_orphans(new_config.actor_id, new_expectations)

    :ok
  end

  defp cleanup_orphans(actor_id, new_expectations) do
    current_exp_ids = Enum.map(new_expectations, fn {id, _opts} -> to_string(id) end)

    blocked = Cyclium.Episodes.list_by_status([:blocked])

    blocked
    |> Enum.filter(fn ep ->
      ep.actor_id == to_string(actor_id) &&
        ep.expectation_id not in current_exp_ids
    end)
    |> Enum.each(fn ep ->
      Logger.info(
        "[Cyclium.Reconciler] Canceling orphaned episode #{ep.id} (expectation #{ep.expectation_id} removed)"
      )

      Cyclium.Episodes.cancel(ep.id, "orphan_cleanup")
    end)
  end
end

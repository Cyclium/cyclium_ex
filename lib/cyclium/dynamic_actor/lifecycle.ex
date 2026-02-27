defmodule Cyclium.DynamicActor.Lifecycle do
  @moduledoc """
  Safe lifecycle operations for dynamic actors.

  Provides drain-aware alternatives to `Loader.stop/1` and `Loader.reload/1`
  that wait for active episodes to complete before stopping the actor.

  ## Usage

      # Graceful drain: wait for episodes to finish, then stop
      Lifecycle.drain_and_stop("my_monitor")

      # Graceful reload: drain, then restart from latest DB definition
      Lifecycle.drain_and_reload("my_monitor")

      # Stop all with drain (for deploys)
      Lifecycle.stop_all(drain: true, timeout: 30_000)

      # Check active episodes
      Lifecycle.active_episode_count("my_monitor")

  ## Deploy patterns

  **Rolling deploy:**

      # In application stop callback:
      Cyclium.DynamicActor.Lifecycle.stop_all(drain: true, timeout: 30_000)

  **Blue-green:** The new instance calls `Loader.load_all()` on startup.
  Global name registration ensures only one instance runs per actor.
  """

  require Logger

  alias Cyclium.DynamicActor.Loader

  @default_timeout 60_000
  @poll_interval 500

  @doc """
  Drains a dynamic actor (waits for active episodes to finish) then stops it.

  ## Options

  - `:timeout` — max wait time in ms (default #{@default_timeout}). If exceeded,
    the actor is force-stopped and in-flight episodes will fail.
  """
  def drain_and_stop(actor_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    name = Loader.process_name(actor_id)

    case :global.whereis_name(name) do
      :undefined ->
        {:error, :not_running}

      pid ->
        # Signal the actor to enter drain mode
        GenServer.cast(pid, :enter_drain)
        Logger.info("[Lifecycle] Draining dynamic actor #{actor_id}")

        # Wait for episodes to finish
        case wait_for_drain(pid, timeout) do
          :ok ->
            Logger.info("[Lifecycle] Actor #{actor_id} drained, stopping")
            DynamicSupervisor.terminate_child(Cyclium.ActorSupervisor, pid)
            :ok

          :timeout ->
            Logger.warning("[Lifecycle] Drain timeout for #{actor_id}, force stopping")
            DynamicSupervisor.terminate_child(Cyclium.ActorSupervisor, pid)
            {:ok, :force_stopped}
        end
    end
  end

  @doc """
  Drains a dynamic actor then reloads it from the latest DB definition.

  ## Options

  - `:timeout` — max wait time in ms for drain (default #{@default_timeout})
  """
  def drain_and_reload(actor_id, opts \\ []) do
    drain_and_stop(actor_id, opts)
    Loader.load(actor_id)
  end

  @doc """
  Stops all running dynamic actors.

  ## Options

  - `:drain` — if `true`, drain each actor before stopping (default `false`)
  - `:timeout` — per-actor drain timeout in ms (default #{@default_timeout})
  """
  def stop_all(opts \\ []) do
    if Keyword.get(opts, :drain, false) do
      drain_stop_all(opts)
    else
      Loader.stop_all()
    end
  end

  @doc """
  Reloads all enabled dynamic actors.

  ## Options

  - `:drain` — if `true`, drain each actor before stopping (default `false`)
  - `:timeout` — per-actor drain timeout in ms (default #{@default_timeout})
  """
  def reload_all(opts \\ []) do
    stop_all(opts)
    Loader.load_all()
  end

  @doc """
  Returns the number of active episodes for a dynamic actor.
  Returns 0 if the actor is not running.
  """
  def active_episode_count(actor_id) do
    name = Loader.process_name(actor_id)

    case :global.whereis_name(name) do
      :undefined -> 0
      pid -> GenServer.call(pid, :active_episode_count)
    end
  catch
    :exit, _ -> 0
  end

  # --- Private ---

  defp drain_stop_all(opts) do
    import Ecto.Query
    alias Cyclium.Schemas.AgentDefinition

    definitions =
      Cyclium.repo().all(from(d in AgentDefinition, where: d.enabled == true))

    results =
      definitions
      |> Task.async_stream(
        fn defn -> {defn.actor_id, drain_and_stop(defn.actor_id, opts)} end,
        timeout: Keyword.get(opts, :timeout, @default_timeout) + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {_id, result}} -> result
        {:exit, _} -> {:error, :timeout}
      end)

    stopped = Enum.count(results, &(&1 in [:ok, {:ok, :force_stopped}]))

    Logger.info("[Lifecycle] Drain-stopped #{stopped}/#{length(definitions)} dynamic actors")

    {:ok, stopped}
  end

  defp wait_for_drain(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_drain(pid, deadline)
  end

  defp do_wait_drain(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      case GenServer.call(pid, :active_episode_count) do
        0 ->
          :ok

        count ->
          Logger.debug("[Lifecycle] Waiting for #{count} episodes to drain")
          Process.sleep(@poll_interval)
          do_wait_drain(pid, deadline)
      end
    end
  catch
    :exit, _ -> :ok
  end
end

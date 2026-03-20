defmodule Cyclium.EpisodeTask do
  @moduledoc """
  Task wrapper for episode execution. Started by the OTP runner
  under Cyclium.EpisodeSupervisor (DynamicSupervisor).
  """

  use Task, restart: :transient

  def start_link(opts) do
    Task.start_link(fn -> run(opts[:episode_id], opts[:opts] || []) end)
  end

  defp run(episode_id, opts) do
    # Trap exits so current step can finish during graceful shutdown.
    # EXIT signals are handled in do_loop's receive block instead of
    # killing the process mid-step.
    Process.flag(:trap_exit, true)

    episode = Cyclium.Episodes.get!(episode_id)
    Process.put(:cyclium_episode_id, episode_id)

    # Claim gate — only runs if work_claims is configured
    lease_seconds = lease_seconds()

    case Cyclium.WorkClaims.gate_acquire(episode.dedupe_key, Cyclium.NodeIdentity.name(),
           lease_seconds: lease_seconds,
           work_type: "episode"
         ) do
      {:ok, :passthrough} -> :ok
      {:ok, _claim} -> :ok
      {:error, :busy} -> exit(:normal)
    end

    # Start heartbeat for lease renewal if claiming is active
    heartbeat_pid = maybe_start_heartbeat(episode, lease_seconds)

    strategy = resolve_strategy(episode)
    synthesizer = resolve_synthesizer(episode)

    state =
      case {opts[:resume], load_checkpoint(episode_id)} do
        {true, {:ok, checkpoint}} ->
          migrate_checkpoint(episode, strategy, checkpoint)

        _ ->
          trigger = deserialize_trigger(episode.trigger_type, episode.trigger_ref)
          {:ok, initial_state} = strategy.init(episode, trigger)
          initial_state
      end

    try do
      Cyclium.EpisodeRunner.execute_loop(episode, strategy, state, synthesizer: synthesizer)

      # Complete claim on successful completion
      Cyclium.WorkClaims.gate_complete(episode.dedupe_key, Cyclium.NodeIdentity.name())
    rescue
      e ->
        require Logger

        message = Exception.message(e)
        stacktrace = Exception.format_stacktrace(__STACKTRACE__)

        Logger.error(
          "[Cyclium.EpisodeTask] Episode #{episode_id} crashed: #{message}\n#{stacktrace}"
        )

        Cyclium.Episodes.update_status(episode_id, :failed,
          error_class: "crash",
          error_detail: %{
            "exception" => message,
            "stacktrace" => stacktrace |> String.slice(0, 4000)
          }
        )

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode_id,
          actor_id: episode.actor_id,
          status: :failed
        })

        Cyclium.WorkClaims.gate_fail(episode.dedupe_key, Cyclium.NodeIdentity.name(), %{
          "reason" => "crash",
          "exception" => message
        })
    after
      # Safety net: ensure episode is never left in running state regardless
      # of how the process terminates. Catches cases where rescue doesn't fire
      # (e.g. throw, abnormal exit). The only case this can't cover is :kill,
      # which is handled by the StaleEpisodeWatchdog.
      ensure_episode_not_running(episode_id)
      if heartbeat_pid, do: Cyclium.WorkClaims.Heartbeat.stop(heartbeat_pid)
    end
  end

  defp ensure_episode_not_running(episode_id) do
    current = Cyclium.Episodes.get!(episode_id)

    if current.status == :running do
      require Logger

      Logger.warning(
        "[Cyclium.EpisodeTask] Episode #{episode_id} still running at task exit — marking failed"
      )

      Cyclium.Episodes.update_status(episode_id, :failed,
        error_class: "process_terminated",
        error_detail: %{"reason" => "Task exited while episode still running"}
      )

      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: episode_id,
        actor_id: current.actor_id,
        status: :failed
      })

      Cyclium.WorkClaims.gate_fail(current.dedupe_key, Cyclium.NodeIdentity.name(), %{
        "reason" => "process_terminated"
      })
    end
  rescue
    _ -> :ok
  end

  defp migrate_checkpoint(episode, strategy, checkpoint) do
    case resolve_checkpoint_schema(episode) do
      nil ->
        # No schema registered — use raw state
        checkpoint.state

      schema ->
        case schema.migrate_to_current(checkpoint.schema_version, checkpoint.state) do
          {:ok, migrated} ->
            migrated

          {:error, _reason} ->
            # Migration failed — fall back to fresh init
            trigger = deserialize_trigger(episode.trigger_type, episode.trigger_ref)
            {:ok, initial_state} = strategy.init(episode, trigger)
            initial_state
        end
    end
  end

  defp resolve_checkpoint_schema(episode) do
    schemas = Application.get_env(:cyclium, :checkpoint_schemas, %{})
    key = {episode.actor_id, episode.expectation_id}
    Map.get(schemas, key) || Map.get(schemas, episode.actor_id)
  end

  defp resolve_strategy(episode) do
    registry = Application.get_env(:cyclium, :strategy_registry)

    # 1. Registry explicit override — for special-case overrides without changing actor code
    # 2. Expectation-declared strategy — registered in persistent_term when actor boots
    # 3. Raise — a strategy is required
    registry_result =
      if registry && function_exported?(registry, :strategy_for, 2) do
        registry.strategy_for(episode.actor_id, episode.expectation_id)
      end

    registry_result ||
      :persistent_term.get(
        {:cyclium_actor_strategy, safe_to_atom(episode.actor_id),
         safe_to_atom(episode.expectation_id)},
        nil
      ) ||
      raise "No strategy found for #{episode.actor_id}/#{episode.expectation_id}. " <>
              "Declare `strategy: MyModule` on the expectation or configure a :strategy_registry."
  end

  defp resolve_synthesizer(episode) do
    registry = Application.get_env(:cyclium, :strategy_registry)

    # 1. Registry explicit override — kept for per-expectation overrides
    # 2. Actor registration — set in persistent_term when actor GenServer boots
    # 3. Global fallback
    registry_result =
      if registry && function_exported?(registry, :synthesizer_for, 2) do
        registry.synthesizer_for(episode.actor_id, episode.expectation_id)
      end

    result =
      registry_result ||
        :persistent_term.get(
          {:cyclium_expectation_synthesizer, safe_to_atom(episode.actor_id),
           safe_to_atom(episode.expectation_id)},
          nil
        ) ||
        :persistent_term.get({:cyclium_actor_synthesizer, safe_to_atom(episode.actor_id)}, nil) ||
        Application.get_env(:cyclium, :synthesizer)

    # Handle tuple config like {Cyclium.Synthesizer.Interactive, llm: MyLLM}
    case result do
      {mod, _opts} when is_atom(mod) -> mod
      mod when is_atom(mod) -> mod
      _ -> result
    end
  end

  defp load_checkpoint(episode_id) do
    import Ecto.Query

    case Cyclium.repo().one(
           from(c in Cyclium.Schemas.EpisodeCheckpoint,
             where: c.episode_id == ^episode_id,
             order_by: [desc: c.checkpoint_no],
             limit: 1
           )
         ) do
      nil -> :none
      checkpoint -> {:ok, checkpoint}
    end
  end

  defp deserialize_trigger(:schedule, ref), do: struct(Cyclium.Trigger.Schedule, atomize(ref))
  defp deserialize_trigger(:event, ref), do: struct(Cyclium.Trigger.Event, atomize(ref))
  defp deserialize_trigger(:manual, ref), do: struct(Cyclium.Trigger.Manual, atomize(ref))
  defp deserialize_trigger(:workflow, ref), do: struct(Cyclium.Trigger.Workflow, atomize(ref))

  defp deserialize_trigger(:interactive, ref),
    do: struct(Cyclium.Trigger.Interactive, atomize(ref))

  defp deserialize_trigger(type, ref) when is_binary(type) do
    deserialize_trigger(String.to_existing_atom(type), ref)
  end

  defp safe_to_atom(value) when is_atom(value), do: value
  defp safe_to_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp atomize(nil), do: %{}

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp maybe_start_heartbeat(episode, lease_seconds) do
    if Cyclium.WorkClaims.configured?() and episode.dedupe_key do
      {:ok, pid} =
        Cyclium.WorkClaims.Heartbeat.start_link(
          dedupe_key: episode.dedupe_key,
          owner_node: Cyclium.NodeIdentity.name(),
          lease_seconds: lease_seconds
        )

      pid
    end
  end

  defp lease_seconds do
    Application.get_env(:cyclium, :work_claims_lease_seconds, 120)
  end
end

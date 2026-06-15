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

    # Receive cancel requests in this process's mailbox; handled at the next
    # step boundary by the runner's drain.
    Cyclium.Bus.subscribe_cancel(episode_id)

    # Claim gate — only runs if work_claims is configured
    lease_seconds = lease_seconds()

    claim_fence =
      case Cyclium.WorkClaims.gate_acquire(episode.dedupe_key, Cyclium.NodeIdentity.name(),
             lease_seconds: lease_seconds,
             work_type: "episode"
           ) do
        {:ok, :passthrough} -> nil
        {:ok, claim} -> claim.fence
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

        {resume?, _} ->
          trigger = deserialize_trigger(episode.trigger_type, episode.trigger_ref)
          {:ok, initial_state} = strategy.init(episode, trigger)

          # On resume with no state checkpoint, let a strategy that opted into
          # journal-based resume (resume_from_block/2) reposition the fresh
          # state from already-journaled steps (e.g. an approved plan).
          if resume?,
            do: maybe_resume_from_block(strategy, episode, initial_state),
            else: initial_state
      end

    try do
      case Cyclium.EpisodeRunner.execute_loop(episode, strategy, state,
             synthesizer: synthesizer,
             claim_fence: claim_fence
           ) do
        {:error, :claim_lost} ->
          # The lease was stolen mid-run; the new owner is driving this episode
          # now. Do NOT complete the claim or touch the episode row — leave both
          # to the owner so we don't clobber its outcome or double-deliver.
          require Logger

          Logger.warning(
            "[Cyclium.EpisodeTask] Episode #{episode_id} lost its work claim mid-run — " <>
              "abandoning to the new owner"
          )

        _ ->
          # Release the claim. (Failures already set episode status in the runner.)
          Cyclium.WorkClaims.gate_complete(episode.dedupe_key, Cyclium.NodeIdentity.name())
      end
    rescue
      e ->
        require Logger

        message = Exception.message(e)
        stacktrace = Exception.format_stacktrace(__STACKTRACE__)

        Logger.error(
          "[Cyclium.EpisodeTask] Episode #{episode_id} crashed: #{message}\n#{stacktrace}"
        )

        error_detail = %{
          "exception" => message,
          "stacktrace" => stacktrace |> String.slice(0, 4000)
        }

        Cyclium.Episodes.update_status(episode_id, :failed,
          error_class: "crash",
          error_detail: error_detail
        )

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode_id,
          actor_id: episode.actor_id,
          status: :failed,
          error_class: "crash",
          error_detail: error_detail
        })

        Cyclium.WorkClaims.gate_fail(episode.dedupe_key, Cyclium.NodeIdentity.name(), %{
          "reason" => "crash",
          "exception" => message
        })
    after
      # Safety net: ensure the episode is never left :running regardless of how
      # the process terminates — catches cases where the rescue doesn't fire
      # (throw, abnormal exit). A hard :kill can't be covered here; those stale
      # :running episodes are recovered by `Cyclium.Recovery.sweep/1` instead.
      #
      # Skip when the claim was lost mid-run: the new owner is driving the
      # episode, so we must not mark its row failed.
      unless Process.get(:cyclium_claim_lost) do
        ensure_episode_not_running(episode_id)
      end

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

      error_detail = %{"reason" => "Task exited while episode still running"}

      Cyclium.Episodes.update_status(episode_id, :failed,
        error_class: "process_terminated",
        error_detail: error_detail
      )

      Cyclium.Bus.broadcast("episode.failed", %{
        episode_id: episode_id,
        actor_id: current.actor_id,
        status: :failed,
        error_class: "process_terminated",
        error_detail: error_detail
      })

      Cyclium.WorkClaims.gate_fail(current.dedupe_key, Cyclium.NodeIdentity.name(), %{
        "reason" => "process_terminated"
      })
    end
  rescue
    _ -> :ok
  end

  defp maybe_resume_from_block(strategy, episode, state) do
    if function_exported?(strategy, :resume_from_block, 2) do
      case strategy.resume_from_block(state, episode) do
        {:ok, resumed} -> resumed
        _ -> state
      end
    else
      state
    end
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

          {:error, reason} ->
            # Migration failed — fall back to fresh init. This restarts the
            # episode from scratch, so any pre-block/pre-checkpoint side effects
            # will replay; log loudly rather than silently starting over.
            require Logger

            Logger.warning(
              "[Cyclium.EpisodeTask] Checkpoint migration failed for episode #{episode.id} " <>
                "(v#{checkpoint.schema_version}: #{inspect(reason)}) — restarting from fresh init"
            )

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

  defp safe_to_atom(value) when is_binary(value) do
    # Used to build persistent_term lookup keys for an actor/expectation. If the
    # atom doesn't exist, neither does any registration under it — return the
    # string so the lookup simply misses (and the caller falls back / raises a
    # clear "no strategy" error) rather than crashing with ArgumentError.
    case Cyclium.AtomGuard.existing_atom(value) do
      {:ok, atom} -> atom
      :error -> value
    end
  end

  defp atomize(nil), do: %{}

  defp atomize(map) when is_map(map) do
    # Convert known keys (trigger struct fields) to atoms so struct/1 picks them
    # up. A stored key with no existing atom is left as a string rather than
    # crashing on String.to_existing_atom/1 — struct/1 ignores unknown keys
    # either way. No atoms are minted (pure existing-atom lookup).
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        case Cyclium.AtomGuard.existing_atom(k) do
          {:ok, atom} -> {atom, v}
          :error -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  defp maybe_start_heartbeat(episode, lease_seconds) do
    if Cyclium.WorkClaims.configured?() and episode.dedupe_key do
      {:ok, pid} =
        Cyclium.WorkClaims.Heartbeat.start_link(
          dedupe_key: episode.dedupe_key,
          owner_node: Cyclium.NodeIdentity.name(),
          lease_seconds: lease_seconds,
          task_pid: self()
        )

      pid
    end
  end

  defp lease_seconds do
    Application.get_env(:cyclium, :work_claims_lease_seconds, 120)
  end
end

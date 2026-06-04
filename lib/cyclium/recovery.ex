defmodule Cyclium.Recovery do
  @moduledoc """
  Recovers orphaned episodes after server restarts.

  After a deploy or crash, in-flight episodes are left as `:running` in the DB.
  `sweep/1` finds these stale episodes and either restarts or fails them based
  on the expectation's `recovery_policy`.

  ## Multi-node coordination

  All nodes in the cluster run the same sweep after boot. Coordination is
  DB-based via optimistic claims — `Episodes.claim_for_recovery/1` sets the
  episode's phase to `"recovering"` only if it's still `:running`. First node
  to claim wins; others silently skip.

  ## Policy resolution order

  1. Compiled actor registry — looks up `recovery_policy` from the actor
     module's compiled expectations
  2. DB agent definitions — falls back to `cyclium_agent_definitions` table
     for dynamic actors not in the compiled registry
  3. Default — `:fail` if the actor is unknown in both

  ## Workflow reconciliation

  `reconcile_workflows/0` handles the inverse problem: workflow instances
  stuck in `:running` because the WorkflowEngine missed a Bus event during
  a restart. It finds steps marked `"running"` in `step_states` whose
  episodes have already reached a terminal state, and re-broadcasts the
  Bus event so the engine can advance the workflow.

  Call `reconcile_workflows/0` after `sweep/1` and after workflow configs
  are registered.

  ## Usage

  Typically called from the host app's supervisor with a startup delay:

      {Task, fn ->
        Process.sleep(:timer.minutes(2))
        Cyclium.Recovery.sweep()
        Cyclium.Recovery.reconcile_workflows()
      end}

  ## Options

    * `:stale_after_ms` — consider an episode stale if no step journal activity
      for this long (default: 2 minutes)
    * `:actor_registry` — map of `%{"actor_id" => ActorModule}` for compiled
      actors. Must match the `identifier()` declared in each actor's DSL block.
      Dynamic actors not in this map are resolved from the DB automatically.
    * `:resolve_policy` — `(episode -> :fail | :restart)` callback for custom
      policy resolution. Overrides `:actor_registry` if both are provided.
    * `:source_stack` — restrict the sweep to episodes originated by this
      stack. Defaults to `Application.get_env(:cyclium, :stack_slug)`. Pass
      `nil` explicitly to sweep globally (single-stack mode).

  ## Examples

      # Recommended: pass compiled actors, dynamic actors resolved from DB
      Cyclium.Recovery.sweep(
        actor_registry: %{
          "project_health_actor" => MyApp.Actors.ProjectHealthActor
        }
      )

      # No registry — dynamic actors still resolved from DB
      Cyclium.Recovery.sweep()

      # Custom: pass a resolve_policy function
      Cyclium.Recovery.sweep(
        resolve_policy: fn _episode -> :restart end
      )
  """

  require Logger

  import Ecto.Query

  alias Cyclium.Episodes
  alias Cyclium.Schemas.AgentDefinition
  alias Cyclium.Schemas.WorkflowInstance

  @default_stale_ms :timer.minutes(2)

  @doc """
  Sweep for orphaned `:running` episodes and recover them.

  Returns `{:ok, %{restarted: n, failed: n, skipped: n}}`.
  """
  def sweep(opts \\ []) do
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @default_stale_ms)
    source_stack = Keyword.get(opts, :source_stack, Cyclium.StackSlug.current())

    actor_registry = Keyword.get(opts, :actor_registry, %{})

    resolve_policy =
      cond do
        Keyword.has_key?(opts, :resolve_policy) ->
          Keyword.fetch!(opts, :resolve_policy)

        true ->
          &resolve_policy_from_registry(&1, actor_registry)
      end

    # Shuffle so every node claims a different episode first. Without this, all
    # nodes wake on the same timer, see the same (unordered) stale list, and the
    # node with the lowest DB latency wins the optimistic claim for episode #1,
    # then #2, then the whole list — concentrating recovery on one node. A
    # per-node shuffle decorrelates the claim order so wins spread across the
    # cluster (the optimistic claim still guarantees exactly-once recovery).
    stale =
      Episodes.list_stale_running(stale_after_ms, source_stack: source_stack)
      |> Enum.shuffle()

    Logger.info(
      "Recovery sweep found #{length(stale)} stale episode(s) (stack=#{inspect(source_stack)})"
    )

    results =
      Enum.map(stale, fn episode ->
        case claim_episode(episode) do
          {:ok, claimed} ->
            recover_episode(claimed, resolve_policy, actor_registry)

          {:error, _} ->
            :skipped
        end
      end)

    counts = %{
      restarted: Enum.count(results, &(&1 == :restarted)),
      failed: Enum.count(results, &(&1 == :failed)),
      skipped: Enum.count(results, &(&1 == :skipped))
    }

    :telemetry.execute(
      [:cyclium, :recovery, :sweep],
      counts,
      %{stale_after_ms: stale_after_ms}
    )

    Logger.info("Recovery sweep complete: #{inspect(counts)}")

    {:ok, counts}
  end

  defp recover_episode(episode, resolve_policy, actor_registry) do
    policy = resolve_policy.(episode)

    case policy do
      :restart ->
        Logger.info("Restarting episode",
          cyclium_episode_id: episode.id,
          cyclium_actor_id: episode.actor_id,
          cyclium_expectation_id: episode.expectation_id
        )

        # Reset status to :running (clear the "recovering" phase)
        Episodes.update_status(episode.id, :running, phase: nil)
        restart_enqueue(episode, actor_registry)
        :restarted

      :fail ->
        Logger.info("Failing orphaned episode",
          cyclium_episode_id: episode.id,
          cyclium_actor_id: episode.actor_id,
          cyclium_expectation_id: episode.expectation_id
        )

        error_detail = %{"reason" => "Server restart recovery — policy: fail"}

        Episodes.update_status(episode.id, :failed,
          error_class: "orphaned",
          error_detail: error_detail
        )

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          error_class: "orphaned",
          error_detail: error_detail,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        :failed
    end
  end

  # Hand a recovered :restart episode to its live actor process so it runs under
  # `max_concurrent_episodes` + the actor's queue, rather than spawning directly
  # under the local EpisodeSupervisor (which would bypass backpressure and let a
  # single node run every recovered episode at once). Falls back to a direct
  # runner enqueue when the actor process can't be located on this node —
  # preserving the original behavior for actors not reachable from here.
  defp restart_enqueue(episode, actor_registry) do
    case actor_pid(episode.actor_id, actor_registry) do
      nil ->
        Cyclium.Mode.runner_for(episode.actor_id).enqueue(episode.id)

      pid ->
        send(pid, {:recover_episode, episode.id})
    end
  end

  # Resolve the running actor process for an actor_id, in order of reliability:
  #
  #   1. `Cyclium.ActorProcessRegistry` — every actor (compiled or dynamic)
  #      registers here under its actor_id on boot, regardless of the `name:` it
  #      was started under. This is the authoritative local lookup.
  #   2. The recovery `actor_registry` module name (`Process.whereis/1`) — a
  #      fallback for the rare case the process registry isn't running.
  #   3. The dynamic actor's global name (`:"cyclium_dynamic_<id>"`) — covers a
  #      dynamic actor living on another node (single global instance).
  #
  # Returns `nil` when none resolve — the caller then enqueues directly.
  defp actor_pid(actor_id, actor_registry) do
    registered_actor_pid(actor_id) ||
      compiled_actor_pid(Map.get(actor_registry, actor_id)) ||
      dynamic_actor_pid(actor_id)
  end

  defp registered_actor_pid(actor_id) do
    registry = Cyclium.Actor.Server.actor_process_registry()

    if Process.whereis(registry) do
      case Registry.lookup(registry, to_string(actor_id)) do
        [{pid, _} | _] -> pid
        [] -> nil
      end
    end
  end

  defp compiled_actor_pid(module) when is_atom(module) and not is_nil(module),
    do: Process.whereis(module)

  defp compiled_actor_pid(_), do: nil

  defp dynamic_actor_pid(actor_id) do
    case :global.whereis_name(:"cyclium_dynamic_#{actor_id}") do
      :undefined -> nil
      pid -> pid
    end
  end

  defp claim_episode(episode) do
    if Cyclium.WorkClaims.configured?() and episode.dedupe_key do
      case Cyclium.WorkClaims.gate_acquire(episode.dedupe_key, node_name(), work_type: "recovery") do
        {:ok, _claim} -> Episodes.claim_for_recovery(episode.id)
        {:error, :busy} -> {:error, :busy}
      end
    else
      Episodes.claim_for_recovery(episode.id)
    end
  end

  defp node_name, do: Cyclium.NodeIdentity.name()

  defp resolve_policy_from_registry(episode, registry) do
    case Map.get(registry, episode.actor_id) do
      nil -> resolve_policy_from_db(episode)
      actor_module -> resolve_policy_from_module(episode, actor_module)
    end
  end

  defp resolve_policy_from_module(episode, actor_module) do
    with true <- function_exported?(actor_module, :__cyclium_expectations__, 0),
         raw_expectations <- actor_module.__cyclium_expectations__(),
         expectation_id <- String.to_existing_atom(episode.expectation_id),
         {_id, opts} <- List.keyfind(raw_expectations, expectation_id, 0) do
      Keyword.get(opts, :recovery_policy, :fail)
    else
      _ -> :fail
    end
  rescue
    _ -> :fail
  end

  defp resolve_policy_from_db(episode) do
    repo = Cyclium.repo()

    case repo.one(from(d in AgentDefinition, where: d.actor_id == ^episode.actor_id)) do
      nil -> :fail
      defn -> extract_recovery_policy(defn, episode.expectation_id)
    end
  rescue
    _ -> :fail
  end

  defp extract_recovery_policy(defn, expectation_id) do
    expectations =
      case defn.expectations do
        nil -> []
        json when is_binary(json) -> Jason.decode!(json)
        list when is_list(list) -> list
      end

    case Enum.find(expectations, fn exp ->
           to_string(exp["id"] || exp[:id]) == expectation_id
         end) do
      nil -> :fail
      exp -> to_recovery_atom(exp["recovery_policy"] || exp[:recovery_policy])
    end
  rescue
    _ -> :fail
  end

  defp to_recovery_atom("restart"), do: :restart
  defp to_recovery_atom(:restart), do: :restart
  defp to_recovery_atom(_), do: :fail

  # --- Workflow reconciliation ---

  @doc """
  Reconcile running workflow instances after a restart.

  Finds workflow instances in `:running` or `:blocked` status whose step_states
  contain steps marked `"running"` but whose episodes have already reached a
  terminal state (`:done`, `:failed`, `:canceled`). For each stale step,
  re-broadcasts the appropriate Bus event so the WorkflowEngine can advance
  the workflow.

  Should be called after `sweep/1` and after workflow configs are registered
  (compiled modules booted, dynamic workflows loaded).

  ## Options

    * `:source_stack` — restrict reconciliation to instances originated by
      this stack. Defaults to `Application.get_env(:cyclium, :stack_slug)`.
      Pass `nil` explicitly to reconcile globally.

  Returns `{:ok, %{replayed: n, skipped: n}}`.
  """
  def reconcile_workflows(opts \\ []) do
    repo = Cyclium.repo()
    source_stack = Keyword.get(opts, :source_stack, Cyclium.StackSlug.current())

    instances =
      from(wi in WorkflowInstance, where: wi.status in [:running, :blocked])
      |> filter_workflow_source_stack(source_stack)
      |> repo.all()

    results =
      Enum.flat_map(instances, fn instance ->
        reconcile_instance_steps(instance)
      end)

    counts = %{
      replayed: Enum.count(results, &(&1 == :replayed)),
      skipped: Enum.count(results, &(&1 == :skipped))
    }

    if counts.replayed > 0 do
      Logger.info("Workflow reconciliation replayed #{counts.replayed} stale step event(s)")
    end

    {:ok, counts}
  rescue
    e ->
      Logger.warning("Workflow reconciliation failed: #{inspect(e)}")
      {:ok, %{replayed: 0, skipped: 0}}
  end

  defp reconcile_instance_steps(instance) do
    instance.step_states
    |> Enum.filter(fn {_step_id, state} -> state["status"] == "running" end)
    |> Enum.map(fn {step_id, step_state} ->
      reconcile_step(instance, step_id, step_state)
    end)
  end

  defp reconcile_step(instance, step_id, step_state) do
    episode_id = step_state["episode_id"]

    if episode_id do
      case Episodes.get(episode_id) do
        %{status: :done} = episode ->
          replay_terminal_event("episode.completed", instance, step_id, episode)
          :replayed

        %{status: status} = episode when status in [:failed, :canceled] ->
          event = if status == :failed, do: "episode.failed", else: "episode.canceled"
          replay_terminal_event(event, instance, step_id, episode)
          :replayed

        _ ->
          # Episode still running or not found — leave for episode sweep
          :skipped
      end
    else
      :skipped
    end
  rescue
    _ -> :skipped
  end

  defp filter_workflow_source_stack(query, nil), do: query

  defp filter_workflow_source_stack(query, source_stack) do
    slug = to_string(source_stack)
    from(wi in query, where: wi.source_stack == ^slug or is_nil(wi.source_stack))
  end

  defp replay_terminal_event(event_type, instance, step_id, episode) do
    Logger.info("Replaying #{event_type} for stale workflow step",
      cyclium_workflow_instance_id: instance.id,
      cyclium_workflow_step_id: step_id,
      cyclium_episode_id: episode.id
    )

    Cyclium.Bus.broadcast(event_type, %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: episode.status,
      workflow_instance_id: instance.id,
      workflow_step_id: step_id
    })
  end
end

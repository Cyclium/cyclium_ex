defmodule Cyclium.WorkflowEngine do
  @moduledoc """
  GenServer that coordinates multi-actor workflows.

  Subscribes to Bus events for workflow triggers and episode terminal events,
  advances step execution based on dependency graphs and failure policies.
  """

  use GenServer
  require Logger

  alias Cyclium.Workflow.Config
  alias Cyclium.WorkflowInstances
  alias Cyclium.Schemas.WorkflowInstance

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Register a workflow module at runtime."
  @spec register_workflow(GenServer.server(), module()) :: :ok
  def register_workflow(server \\ __MODULE__, workflow_module) do
    GenServer.cast(server, {:register_workflow, workflow_module})
  end

  @doc "Register a dynamic workflow (DB-defined) with pre-built config and input maps."
  @spec register_dynamic_workflow(GenServer.server(), Config.t(), map()) :: :ok
  def register_dynamic_workflow(server \\ __MODULE__, config, input_maps \\ %{}) do
    GenServer.cast(server, {:register_dynamic_workflow, config, input_maps})
  end

  @doc "Unregister a workflow by workflow_id."
  @spec unregister_workflow(GenServer.server(), binary()) :: :ok
  def unregister_workflow(server \\ __MODULE__, workflow_id) do
    GenServer.cast(server, {:unregister_workflow, workflow_id})
  end

  @doc """
  Start a new workflow instance from a trigger (compiled workflow module).

  ## Options

    - `:mode` — `:live` (default) or `:dry_run`
    - `:dry_run_opts` — map of dry run options (e.g., `%{persist_findings: true}`)
  """
  @spec start_workflow(GenServer.server(), module(), map(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def start_workflow(server \\ __MODULE__, workflow_module, trigger_data, opts \\ []) do
    GenServer.call(server, {:start_workflow, workflow_module, trigger_data, opts})
  end

  @doc """
  Start a new dynamic workflow instance by workflow_id.

  ## Options

    - `:mode` — `:live` (default) or `:dry_run`
    - `:dry_run_opts` — map of dry run options (e.g., `%{persist_findings: true}`)
  """
  @spec start_dynamic_workflow(GenServer.server(), binary(), map(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def start_dynamic_workflow(server \\ __MODULE__, workflow_id, trigger_data, opts \\ []) do
    GenServer.call(server, {:start_dynamic_workflow, workflow_id, trigger_data, opts})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    modules = Keyword.get(opts, :workflows, Application.get_env(:cyclium, :workflows, []))

    state = %{
      workflows: %{},
      workflow_modules: MapSet.new(),
      retry_timers: %{},
      input_maps: %{}
    }

    state = Enum.reduce(modules, state, &do_register_workflow/2)

    # Subscribe to Bus for all events
    Cyclium.Bus.subscribe()

    {:ok, state}
  end

  @impl true
  def handle_call({:start_workflow, workflow_module, trigger_data, opts}, _from, state) do
    config = workflow_module.__workflow_config__()

    case start_workflow_instance(config, trigger_data, opts, state) do
      {:ok, instance_id, new_state} ->
        {:reply, {:ok, instance_id}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:start_dynamic_workflow, workflow_id, trigger_data, opts}, _from, state) do
    full_id = "dynamic:#{workflow_id}"

    case resolve_config(full_id, state) do
      nil ->
        {:reply, {:error, :not_found}, state}

      config ->
        case start_workflow_instance(config, trigger_data, opts, state) do
          {:ok, instance_id, new_state} ->
            {:reply, {:ok, instance_id}, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_cast({:register_workflow, module}, state) do
    {:noreply, do_register_workflow(module, state)}
  end

  @impl true
  def handle_cast({:register_dynamic_workflow, config, input_maps}, state) do
    {:noreply, do_register_dynamic_workflow(config, input_maps, state)}
  end

  @impl true
  def handle_cast({:unregister_workflow, workflow_id}, state) do
    {:noreply, do_unregister_workflow(workflow_id, state)}
  end

  @impl true
  def handle_info({:bus, event_type, payload}, state) do
    state = maybe_trigger_workflow(event_type, payload, state)
    state = maybe_handle_episode_terminal(event_type, payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_step, instance_id, step_id}, state) do
    state = %{state | retry_timers: Map.delete(state.retry_timers, "#{instance_id}:#{step_id}")}

    case WorkflowInstances.get(instance_id) do
      nil ->
        state

      %WorkflowInstance{status: status} when status in [:failed, :canceled, :done] ->
        state

      instance ->
        config = resolve_config(instance.workflow_id, state)

        if config do
          do_start_step(instance, config, step_id, state)
        else
          state
        end
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp do_register_workflow(module, state) do
    config = module.__workflow_config__()

    workflows =
      case config.trigger do
        {:event, event_type} ->
          existing = Map.get(state.workflows, event_type, [])
          Map.put(state.workflows, event_type, [config | existing])

        :manual ->
          state.workflows
      end

    %{state | workflows: workflows, workflow_modules: MapSet.put(state.workflow_modules, module)}
  end

  defp do_register_dynamic_workflow(%Config{} = config, input_maps, state) do
    workflows =
      case config.trigger do
        {:event, event_type} ->
          existing = Map.get(state.workflows, event_type, [])
          # Avoid duplicate registration
          filtered = Enum.reject(existing, &(&1.workflow_id == config.workflow_id))
          Map.put(state.workflows, event_type, [config | filtered])

        :manual ->
          state.workflows
      end

    input_maps_state = Map.put(state.input_maps, config.workflow_id, input_maps)

    Logger.info("[Cyclium.WorkflowEngine] Registered dynamic workflow #{config.workflow_id}")

    %{state | workflows: workflows, input_maps: input_maps_state}
  end

  defp do_unregister_workflow(workflow_id, state) do
    workflows =
      state.workflows
      |> Enum.map(fn {event_type, configs} ->
        {event_type, Enum.reject(configs, &(&1.workflow_id == workflow_id))}
      end)
      |> Enum.reject(fn {_event_type, configs} -> configs == [] end)
      |> Enum.into(%{})

    input_maps = Map.delete(state.input_maps, workflow_id)

    Logger.info("[Cyclium.WorkflowEngine] Unregistered workflow #{workflow_id}")

    %{state | workflows: workflows, input_maps: input_maps}
  end

  defp maybe_trigger_workflow(event_type, payload, state) do
    case Map.get(state.workflows, event_type) do
      nil ->
        state

      configs ->
        Enum.reduce(configs, state, fn config, acc ->
          case start_workflow_instance(config, payload, [], acc) do
            {:ok, _instance_id, new_state} -> new_state
            {:error, _} -> acc
          end
        end)
    end
  end

  defp start_workflow_instance(%Config{} = config, trigger_data, opts, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    mode = Keyword.get(opts, :mode, :live)

    dry_run_opts =
      case Keyword.get(opts, :dry_run_opts) do
        nil -> nil
        m when is_map(m) -> m |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
        l when is_list(l) -> l |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
      end

    # Initialize step_states for all steps
    initial_step_states =
      config.steps
      |> Enum.map(fn {step_id, _step} ->
        {to_string(step_id), %{"status" => "pending", "attempts" => 0}}
      end)
      |> Enum.into(%{})

    attrs = %{
      workflow_id: config.workflow_id,
      trigger_ref: trigger_data,
      status: :running,
      mode: to_string(mode),
      dry_run_opts: dry_run_opts,
      step_states: initial_step_states,
      started_at: now,
      created_at: now,
      updated_at: now
    }

    case WorkflowInstances.create(attrs) do
      {:ok, instance} ->
        :telemetry.execute([:cyclium, :workflow, :started], %{count: 1}, %{
          workflow_id: config.workflow_id,
          instance_id: instance.id
        })

        Cyclium.Bus.broadcast("workflow.started", %{
          workflow_id: config.workflow_id,
          instance_id: instance.id,
          mode: instance.mode
        })

        # Start ready steps (those with no dependencies)
        state = start_ready_steps(instance, config, state)
        {:ok, instance.id, state}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_handle_episode_terminal(event_type, payload, state)
       when event_type in [
              "episode.completed",
              "episode.failed",
              "episode.canceled",
              "episode.dropped"
            ] do
    case payload do
      %{workflow_instance_id: wf_id, workflow_step_id: step_id}
      when is_binary(wf_id) and wf_id != "" and not is_nil(step_id) ->
        handle_episode_terminal(wf_id, step_id, event_type, payload, state)

      _ ->
        state
    end
  end

  defp maybe_handle_episode_terminal(_event_type, _payload, state), do: state

  defp handle_episode_terminal(instance_id, step_id, event_type, payload, state) do
    case WorkflowInstances.get(instance_id) do
      nil ->
        state

      %WorkflowInstance{status: status} when status in [:done, :failed, :canceled] ->
        state

      instance ->
        config = resolve_config(instance.workflow_id, state)

        if config do
          case event_type do
            "episode.completed" ->
              handle_step_completed(instance, config, step_id, payload, state)

            terminal when terminal in ["episode.failed", "episode.canceled", "episode.dropped"] ->
              handle_step_failed(instance, config, step_id, state)
          end
        else
          state
        end
    end
  end

  defp handle_step_completed(instance, config, step_id, payload, state) do
    step_atom = String.to_existing_atom(step_id)

    # Extract result from episode
    result = extract_step_result(payload)

    # Update step_states
    step_states =
      Map.put(instance.step_states, step_id, %{
        "status" => "done",
        "episode_id" => payload.episode_id,
        "result" => result,
        "attempts" => get_in(instance.step_states, [step_id, "attempts"]) || 1
      })

    {:ok, instance} = WorkflowInstances.update_step_states(instance.id, step_states)

    :telemetry.execute([:cyclium, :workflow, :step_completed], %{count: 1}, %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      step_id: step_atom
    })

    # Check if all steps done
    all_done? =
      Enum.all?(step_states, fn {_k, v} -> v["status"] == "done" end)

    if all_done? do
      complete_workflow(instance, config, state)
    else
      start_ready_steps(instance, config, state)
    end
  end

  defp handle_step_failed(instance, config, step_id, state) do
    step_atom = String.to_existing_atom(step_id)
    policy = Map.get(config.failure_policies, step_atom, %{policy: :abort})
    current_attempts = get_in(instance.step_states, [step_id, "attempts"]) || 1

    :telemetry.execute([:cyclium, :workflow, :step_failed], %{count: 1}, %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      step_id: step_atom
    })

    case policy do
      %{policy: :abort} ->
        fail_workflow(instance, config, step_id, state)

      %{policy: :retry, max_step_attempts: max_attempts} = retry_policy ->
        if current_attempts < max_attempts do
          retry_step(instance, config, step_id, current_attempts, retry_policy, state)
        else
          # Exhausted retries, escalate to abort
          fail_workflow(instance, config, step_id, state)
        end

      %{policy: :retry} = retry_policy ->
        max_attempts = Map.get(retry_policy, :max_step_attempts, 3)

        if current_attempts < max_attempts do
          retry_step(instance, config, step_id, current_attempts, retry_policy, state)
        else
          fail_workflow(instance, config, step_id, state)
        end

      %{policy: :pause} ->
        # Update step status
        step_states =
          Map.put(instance.step_states, step_id, %{
            "status" => "paused",
            "attempts" => current_attempts
          })

        WorkflowInstances.update_step_states(instance.id, step_states)
        WorkflowInstances.update_status(instance.id, :blocked)
        state
    end
  end

  defp retry_step(instance, config, step_id, current_attempts, retry_policy, state) do
    backoff_ms = Map.get(retry_policy, :backoff_ms, 5_000)

    :telemetry.execute([:cyclium, :workflow, :step_retried], %{count: 1}, %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      step_id: String.to_existing_atom(step_id),
      attempt: current_attempts + 1
    })

    # Update step to pending with incremented attempts
    step_states =
      Map.put(instance.step_states, step_id, %{
        "status" => "retrying",
        "attempts" => current_attempts + 1
      })

    WorkflowInstances.update_step_states(instance.id, step_states)

    # Schedule retry after backoff
    timer_key = "#{instance.id}:#{step_id}"
    timer_ref = Process.send_after(self(), {:retry_step, instance.id, step_id}, backoff_ms)

    %{state | retry_timers: Map.put(state.retry_timers, timer_key, timer_ref)}
  end

  defp start_ready_steps(instance, config, state) do
    ready = ready_steps(config, instance.step_states)

    Enum.reduce(ready, state, fn step_id, acc ->
      do_start_step(instance, config, to_string(step_id), acc)
    end)
  end

  defp ready_steps(%Config{} = config, step_states) do
    Enum.filter(config.steps, fn {step_id, step} ->
      step_state = Map.get(step_states, to_string(step_id), %{})
      status = step_state["status"]

      # Step is ready if pending and all deps are done
      status == "pending" and
        Enum.all?(step.depends_on, fn dep ->
          dep_state = Map.get(step_states, to_string(dep), %{})
          dep_state["status"] == "done"
        end)
    end)
    |> Enum.map(fn {step_id, _step} -> step_id end)
  end

  defp do_start_step(instance, config, step_id, state) when is_binary(step_id) do
    step_atom = String.to_existing_atom(step_id)
    step_config = Map.fetch!(config.steps, step_atom)

    # Re-read instance to get latest step_states (important for parallel step starts)
    fresh_instance = WorkflowInstances.get!(instance.id)

    # Build prior results from completed steps
    prior = build_prior_results(fresh_instance.step_states)

    input = resolve_step_input(config, step_atom, fresh_instance.trigger_ref, prior, state)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    actor_id = resolve_actor_id(step_config.actor)

    # Create episode with workflow correlation (inheriting mode from instance)
    # Merge per-step overrides from dry_run_opts["steps"][step_id] into the episode opts
    episode_dry_run_opts = resolve_step_dry_run_opts(fresh_instance.dry_run_opts, step_id)

    episode_attrs = %{
      actor_id: actor_id,
      expectation_id: to_string(step_config.expectation),
      trigger_type: :workflow,
      trigger_ref: %{
        workflow_instance_id: instance.id,
        workflow_step_id: step_id,
        input: input
      },
      workflow_instance_id: instance.id,
      workflow_step_id: step_id,
      mode: fresh_instance.mode || "live",
      dry_run_opts: episode_dry_run_opts,
      status: :running,
      started_at: now
    }

    case Cyclium.Episodes.create(episode_attrs) do
      {:ok, episode} ->
        # Enqueue episode
        runner().enqueue(episode.id)

        # Update step_states (use fresh_instance to avoid overwriting parallel step updates)
        current_attempts = get_in(fresh_instance.step_states, [step_id, "attempts"]) || 0

        step_states =
          Map.put(fresh_instance.step_states, step_id, %{
            "status" => "running",
            "episode_id" => episode.id,
            "attempts" => max(current_attempts, 1)
          })

        WorkflowInstances.update_step_states(instance.id, step_states)

        :telemetry.execute([:cyclium, :workflow, :step_started], %{count: 1}, %{
          workflow_id: config.workflow_id,
          instance_id: instance.id,
          step_id: step_atom,
          episode_id: episode.id
        })

        state

      {:error, reason} ->
        Logger.error(
          "[Cyclium.WorkflowEngine] Failed to create episode for step #{step_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp complete_workflow(instance, config, state) do
    WorkflowInstances.update_status(instance.id, :done)

    :telemetry.execute([:cyclium, :workflow, :completed], %{count: 1}, %{
      workflow_id: config.workflow_id,
      instance_id: instance.id
    })

    Cyclium.Bus.broadcast("workflow.completed", %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      mode: instance.mode
    })

    state
  end

  defp fail_workflow(instance, config, step_id, state) do
    # Cancel any running steps
    Enum.each(instance.step_states, fn {sid, step_state} ->
      if sid != step_id and step_state["status"] == "running" do
        if episode_id = step_state["episode_id"] do
          Cyclium.Episodes.cancel(episode_id, "workflow_aborted")
        end
      end
    end)

    # Cancel any pending retry timers
    state =
      Enum.reduce(state.retry_timers, state, fn {key, timer_ref}, acc ->
        if String.starts_with?(key, "#{instance.id}:") do
          Process.cancel_timer(timer_ref)
          %{acc | retry_timers: Map.delete(acc.retry_timers, key)}
        else
          acc
        end
      end)

    WorkflowInstances.update_status(instance.id, :failed)

    :telemetry.execute([:cyclium, :workflow, :failed], %{count: 1}, %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      step_id: step_id
    })

    Cyclium.Bus.broadcast("workflow.failed", %{
      workflow_id: config.workflow_id,
      instance_id: instance.id,
      step_id: step_id,
      mode: instance.mode
    })

    state
  end

  defp extract_step_result(payload) do
    episode =
      case Cyclium.Episodes.get(payload.episode_id) do
        nil -> %{}
        ep -> ep
      end

    %{
      "classification" => episode |> Map.get(:classification),
      "summary" => episode |> Map.get(:summary),
      "confidence" => episode |> Map.get(:confidence)
    }
  end

  defp build_prior_results(step_states) do
    step_states
    |> Enum.filter(fn {_k, v} -> v["status"] == "done" and v["result"] end)
    |> Enum.map(fn {k, v} ->
      atom_key =
        try do
          String.to_existing_atom(k)
        rescue
          ArgumentError -> String.to_atom(k)
        end

      result =
        v["result"]
        |> Enum.map(fn {rk, rv} ->
          atom_rk =
            try do
              String.to_existing_atom(rk)
            rescue
              ArgumentError -> String.to_atom(rk)
            end

          {atom_rk, rv}
        end)
        |> Enum.into(%{})

      {atom_key, result}
    end)
    |> Enum.into(%{})
  end

  defp resolve_config(workflow_id, state) do
    Enum.find_value(state.workflows, fn {_event, configs} ->
      Enum.find(configs, fn c -> c.workflow_id == workflow_id end)
    end)
  end

  defp resolve_step_input(config, step_atom, trigger_ref, prior, state) do
    if String.starts_with?(config.workflow_id, "dynamic:") do
      # Dynamic workflow — resolve via input_map
      input_maps = Map.get(state.input_maps, config.workflow_id, %{})
      input_map = Map.get(input_maps, step_atom) || Map.get(input_maps, to_string(step_atom))

      Cyclium.DynamicWorkflow.InputResolver.resolve(input_map, trigger_ref, prior)
    else
      # Compiled workflow — call module function
      workflow_module = String.to_existing_atom(config.workflow_id)

      try do
        workflow_module.__workflow_step_input__(step_atom, trigger_ref, prior)
      rescue
        e ->
          Logger.warning(
            "[Cyclium.WorkflowEngine] input_fn failed for step #{step_atom}: #{inspect(e)}"
          )

          %{}
      end
    end
  end

  defp resolve_actor_id(actor_id) when is_binary(actor_id), do: actor_id

  defp resolve_actor_id(actor_module) when is_atom(actor_module) do
    if function_exported?(actor_module, :__cyclium_config__, 0) do
      config = actor_module.__cyclium_config__()
      to_string(config.actor_id)
    else
      actor_module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  # Merges per-step overrides from dry_run_opts["steps"][step_id] into the
  # base dry_run_opts. Step-specific keys override global keys. The "steps"
  # key itself is removed from the episode's opts (it's workflow-level only).
  defp resolve_step_dry_run_opts(nil, _step_id), do: nil

  defp resolve_step_dry_run_opts(dry_run_opts, step_id) when is_map(dry_run_opts) do
    step_overrides =
      case Map.get(dry_run_opts, "steps") do
        %{} = steps -> Map.get(steps, step_id) || %{}
        _ -> %{}
      end

    dry_run_opts
    |> Map.delete("steps")
    |> Map.merge(step_overrides)
    |> case do
      empty when map_size(empty) == 0 -> nil
      merged -> merged
    end
  end

  defp runner do
    Application.get_env(:cyclium, :runner, Cyclium.Runner.OTP)
  end
end

defmodule Cyclium.DynamicWorkflow.Loader do
  @moduledoc """
  Loads DB-defined workflow definitions and registers them with WorkflowEngine.

  ## Usage

      # Load all enabled workflow definitions at startup
      Cyclium.DynamicWorkflow.Loader.load_all()

      # Load a single workflow by workflow_id
      Cyclium.DynamicWorkflow.Loader.load("vendor_onboarding")

      # Unload (unregister) a workflow
      Cyclium.DynamicWorkflow.Loader.unload("vendor_onboarding")

      # Reload after definition update
      Cyclium.DynamicWorkflow.Loader.reload("vendor_onboarding")
  """

  require Logger

  import Ecto.Query

  alias Cyclium.Schemas.WorkflowDefinition
  alias Cyclium.Workflow.{Config, StepConfig, DAG}

  defp repo, do: Cyclium.repo()

  @doc """
  Load all enabled workflow definitions from DB and register them.
  Returns `{:ok, loaded_count}`.
  """
  def load_all(engine \\ Cyclium.WorkflowEngine) do
    definitions = repo().all(from(d in WorkflowDefinition, where: d.enabled == true))

    loaded =
      definitions
      |> Enum.map(&load_definition(&1, engine))
      |> Enum.count(&match?({:ok, _}, &1))

    Logger.info(
      "[Cyclium.DynamicWorkflow.Loader] Loaded #{loaded}/#{length(definitions)} dynamic workflows"
    )

    {:ok, loaded}
  end

  @doc """
  Load and register a single workflow definition by workflow_id.
  """
  def load(workflow_id, engine \\ Cyclium.WorkflowEngine) do
    case repo().one(from(d in WorkflowDefinition, where: d.workflow_id == ^workflow_id)) do
      nil -> {:error, :not_found}
      defn -> load_definition(defn, engine)
    end
  end

  @doc """
  Unregister a dynamic workflow from WorkflowEngine.
  """
  def unload(workflow_id, engine \\ Cyclium.WorkflowEngine) do
    full_id = "dynamic:#{workflow_id}"
    Cyclium.WorkflowEngine.unregister_workflow(engine, full_id)
    :ok
  end

  @doc """
  Reload a dynamic workflow (unload + load from latest DB definition).
  """
  def reload(workflow_id, engine \\ Cyclium.WorkflowEngine) do
    unload(workflow_id, engine)
    load(workflow_id, engine)
  end

  # --- Private ---

  defp load_definition(%WorkflowDefinition{} = defn, engine) do
    case build_config(defn) do
      {:ok, config, input_maps} ->
        Cyclium.WorkflowEngine.register_dynamic_workflow(engine, config, input_maps)

        Logger.info("[Cyclium.DynamicWorkflow.Loader] Registered workflow #{defn.workflow_id}")

        {:ok, defn.workflow_id}

      {:error, reason} = err ->
        Logger.error(
          "[Cyclium.DynamicWorkflow.Loader] Failed to load #{defn.workflow_id}: #{inspect(reason)}"
        )

        err
    end
  end

  defp build_config(%WorkflowDefinition{} = defn) do
    steps_raw = parse_json(defn.steps, [])

    trigger =
      case defn.trigger_type do
        "event" -> {:event, defn.trigger_event}
        "manual" -> :manual
      end

    # Build step configs and input maps
    {step_configs, input_maps} =
      Enum.reduce(steps_raw, {%{}, %{}}, fn step, {configs, maps} ->
        id = String.to_atom(step["id"])

        step_config = %StepConfig{
          id: id,
          actor: step["actor_id"],
          expectation: String.to_atom(step["expectation"]),
          input_fn: nil,
          input_map: step["input_map"],
          depends_on: Enum.map(step["depends_on"] || [], &String.to_atom/1),
          requires_approval: step["requires_approval"] || false
        }

        configs = Map.put(configs, id, step_config)
        maps = if step["input_map"], do: Map.put(maps, id, step["input_map"]), else: maps

        {configs, maps}
      end)

    # Build failure policies from step-level config
    failure_policies =
      steps_raw
      |> Enum.filter(& &1["failure_policy"])
      |> Enum.map(fn step ->
        id = String.to_atom(step["id"])
        policy = %{policy: String.to_atom(step["failure_policy"])}

        policy =
          if step["max_step_attempts"],
            do: Map.put(policy, :max_step_attempts, step["max_step_attempts"]),
            else: policy

        policy =
          if step["backoff_ms"],
            do: Map.put(policy, :backoff_ms, step["backoff_ms"]),
            else: policy

        {id, policy}
      end)
      |> Enum.into(%{})

    # Merge with top-level failure_policies if present
    top_policies = parse_json(defn.failure_policies, %{})

    top_policies_atomized =
      top_policies
      |> Enum.map(fn {k, v} ->
        {String.to_atom(k), atomize_policy(v)}
      end)
      |> Enum.into(%{})

    all_policies = Map.merge(failure_policies, top_policies_atomized)

    # Validate DAG
    adjacency = Map.new(step_configs, fn {id, sc} -> {id, sc.depends_on} end)

    case DAG.validate!(adjacency) do
      :ok ->
        config = %Config{
          workflow_id: "dynamic:#{defn.workflow_id}",
          trigger: trigger,
          steps: step_configs,
          failure_policies: all_policies
        }

        {:ok, config, input_maps}

      {:error, {:cycle, node}} ->
        {:error, {:circular_dependency, node}}
    end
  end

  defp atomize_policy(policy) when is_map(policy) do
    base = %{policy: String.to_atom(policy["policy"] || "abort")}

    base =
      if policy["max_step_attempts"],
        do: Map.put(base, :max_step_attempts, policy["max_step_attempts"]),
        else: base

    if policy["backoff_ms"],
      do: Map.put(base, :backoff_ms, policy["backoff_ms"]),
      else: base
  end

  defp parse_json(nil, default), do: default
  defp parse_json("", default), do: default

  defp parse_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> data
      _ -> default
    end
  end

  defp parse_json(data, _default), do: data
end

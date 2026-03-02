defmodule Cyclium.DynamicActor.Loader do
  @moduledoc """
  Loads DB-defined agent definitions and starts them as `DynamicActor`
  processes under `Cyclium.ActorSupervisor`.

  ## Usage

      # Load all enabled definitions at application startup
      Cyclium.DynamicActor.Loader.load_all()

      # Load a single definition by actor_id
      Cyclium.DynamicActor.Loader.load("my_custom_monitor")

      # Stop a running dynamic actor
      Cyclium.DynamicActor.Loader.stop("my_custom_monitor")

      # Reload (stop + start) after definition update
      Cyclium.DynamicActor.Loader.reload("my_custom_monitor")
  """

  require Logger

  import Ecto.Query
  alias Cyclium.Schemas.AgentDefinition

  defp repo, do: Cyclium.repo()

  @doc """
  Loads all enabled agent definitions from DB and starts them.
  Returns `{:ok, started_count}`.
  """
  def load_all do
    definitions = repo().all(from(d in AgentDefinition, where: d.enabled == true))

    started =
      definitions
      |> Enum.map(&start_from_definition/1)
      |> Enum.count(&match?({:ok, _}, &1))

    Logger.info("Started #{started}/#{length(definitions)} dynamic actors")

    {:ok, started}
  end

  @doc """
  Loads and starts a single agent definition by actor_id.
  """
  def load(actor_id) do
    case repo().one(from(d in AgentDefinition, where: d.actor_id == ^actor_id)) do
      nil -> {:error, :not_found}
      defn -> start_from_definition(defn)
    end
  end

  @doc """
  Stops a running dynamic actor by actor_id.
  """
  def stop(actor_id) do
    name = process_name(actor_id)

    case :global.whereis_name(name) do
      :undefined ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(Cyclium.ActorSupervisor, pid)
        :ok
    end
  end

  @doc """
  Reloads a dynamic actor (stop + start from latest DB definition).
  """
  def reload(actor_id) do
    stop(actor_id)
    load(actor_id)
  end

  @doc """
  Stops all running dynamic actors.
  """
  def stop_all do
    definitions = repo().all(from(d in AgentDefinition, where: d.enabled == true))

    stopped =
      definitions
      |> Enum.map(&stop(&1.actor_id))
      |> Enum.count(&(&1 == :ok))

    Logger.info("Stopped #{stopped}/#{length(definitions)} dynamic actors")

    {:ok, stopped}
  end

  @doc """
  Reloads all enabled dynamic actors (stop + start from latest DB definitions).
  """
  def reload_all do
    stop_all()
    load_all()
  end

  @doc """
  Returns the process name for a dynamic actor.
  """
  def process_name(actor_id), do: :"cyclium_dynamic_#{actor_id}"

  # --- Private ---

  defp start_from_definition(%AgentDefinition{} = defn) do
    strategy_module = resolve_strategy_module(defn)
    config = deserialize_config(defn)
    expectations = deserialize_expectations(defn, strategy_module)
    name = process_name(defn.actor_id)

    validate_strategy_outputs(defn)

    case DynamicSupervisor.start_child(Cyclium.ActorSupervisor, {
           Cyclium.DynamicActor,
           name: name, config: config, expectations: expectations
         }) do
      {:ok, pid} ->
        Logger.info("Started dynamic actor (#{inspect(pid)})",
          cyclium_actor_id: defn.actor_id
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Dynamic actor already running",
          cyclium_actor_id: defn.actor_id
        )

        {:ok, pid}

      {:error, reason} = err ->
        Logger.error("Failed to start dynamic actor: #{inspect(reason)}",
          cyclium_actor_id: defn.actor_id
        )

        err
    end
  end

  defp resolve_strategy_module(%AgentDefinition{strategy_template: template})
       when is_binary(template) do
    Cyclium.Strategy.TemplateRegistry.resolve(template)
  end

  defp resolve_strategy_module(_), do: nil

  defp deserialize_config(%AgentDefinition{} = defn) do
    base =
      case defn.config do
        nil -> %{}
        json when is_binary(json) -> Jason.decode!(json, keys: :atoms)
        map when is_map(map) -> map
      end

    Map.merge(
      %{
        actor_id: String.to_atom(defn.actor_id),
        domain: if(defn.domain, do: String.to_atom(defn.domain)),
        synthesizer: nil,
        max_concurrent_episodes: 5,
        episode_overflow: :queue
      },
      base
    )
  end

  defp deserialize_expectations(%AgentDefinition{} = defn, default_strategy) do
    raw =
      case defn.expectations do
        nil -> []
        json when is_binary(json) -> Jason.decode!(json, keys: :atoms)
        list when is_list(list) -> list
      end

    Enum.map(raw, fn exp ->
      id = String.to_atom(to_string(exp[:id] || exp["id"]))
      opts = expectation_to_opts(exp, default_strategy)
      {id, opts}
    end)
  end

  defp expectation_to_opts(exp, default_strategy) do
    opts = []

    # Per-expectation strategy key overrides the actor-level template
    strategy =
      case exp[:strategy] || exp["strategy"] do
        nil -> default_strategy
        s when is_atom(s) -> s
        s when is_binary(s) -> String.to_existing_atom(s)
      end

    opts = if strategy, do: [{:strategy, strategy} | opts], else: opts

    opts =
      case exp[:trigger] || exp["trigger"] do
        %{"type" => "schedule", "interval_ms" => ms} ->
          [{:trigger, {:schedule, ms}} | opts]

        %{"type" => "event", "event_type" => et} ->
          [{:trigger, {:event, et}} | opts]

        %{type: :schedule, interval_ms: ms} ->
          [{:trigger, {:schedule, ms}} | opts]

        %{type: :event, event_type: et} ->
          [{:trigger, {:event, et}} | opts]

        _ ->
          opts
      end

    opts = if exp[:budget], do: [{:budget, exp[:budget]} | opts], else: opts

    opts =
      if exp[:log_strategy], do: [{:log_strategy, to_atom(exp[:log_strategy])} | opts], else: opts

    opts =
      if exp[:recovery_policy],
        do: [{:recovery_policy, to_atom(exp[:recovery_policy])} | opts],
        else: opts

    opts =
      if exp[:subject_key], do: [{:subject_key, to_atom(exp[:subject_key])} | opts], else: opts

    opts = if exp[:debounce_ms], do: [{:debounce_ms, exp[:debounce_ms]} | opts], else: opts
    opts = if exp[:cooldown_ms], do: [{:cooldown_ms, exp[:cooldown_ms]} | opts], else: opts
    opts
  end

  defp to_atom(val) when is_atom(val), do: val
  defp to_atom(val) when is_binary(val), do: String.to_atom(val)

  defp validate_strategy_outputs(%AgentDefinition{} = defn) do
    strategy_config =
      case defn.strategy_config do
        nil -> %{}
        json when is_binary(json) -> Jason.decode!(json) |> then(& &1)
        map when is_map(map) -> map
      end

    case strategy_config do
      %{"outputs" => types} when is_list(types) ->
        Enum.each(types, fn type ->
          unless Cyclium.Output.Adapter.resolve(type) do
            Logger.warning("Output type #{inspect(type)} has no registered adapter",
              cyclium_actor_id: defn.actor_id
            )
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end

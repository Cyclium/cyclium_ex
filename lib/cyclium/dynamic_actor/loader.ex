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
        Cyclium.StrategyConfig.unmark_dynamic(actor_id)
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
  Returns the `:global` name of a dynamic actor: a tuple keyed by the actor id
  string, so looking one up never mints an atom per id.
  """
  @spec process_name(atom() | binary()) :: {:cyclium_dynamic, binary()}
  def process_name(actor_id), do: {:cyclium_dynamic, to_string(actor_id)}

  # --- Private ---

  defp start_from_definition(%AgentDefinition{} = defn) do
    strategy_module = resolve_strategy_module(defn)
    config = deserialize_config(defn)

    case deserialize_expectations(defn, strategy_module) do
      {:ok, expectations} ->
        name = process_name(defn.actor_id)

        validate_strategy_outputs(defn)

        # Lets Cyclium.StrategyConfig read this actor's strategy_config from its
        # definition row; compiled actors never take that path.
        Cyclium.StrategyConfig.mark_dynamic(defn.actor_id)

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

      {:error, reason} = err ->
        Logger.error("Refusing to start dynamic actor: #{inspect(reason)}",
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

  # Definition JSON is decoded with `AtomGuard.key/1`: a key the framework reads
  # already exists as an atom and comes back as one; any other key stays a
  # string and is ignored, so a definition cannot grow the atom table by key.
  defp decode_json(json), do: Jason.decode!(json, keys: &Cyclium.AtomGuard.key/1)

  defp deserialize_config(%AgentDefinition{} = defn) do
    base =
      case defn.config do
        nil -> %{}
        json when is_binary(json) -> decode_json(json)
        map when is_map(map) -> map
      end

    Map.merge(
      %{
        actor_id: Cyclium.AtomGuard.intern!(defn.actor_id),
        domain: if(defn.domain, do: Cyclium.AtomGuard.intern!(defn.domain)),
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
        json when is_binary(json) -> decode_json(json)
        list when is_list(list) -> list
      end

    raw
    |> Enum.reduce_while({:ok, []}, fn exp, {:ok, acc} ->
      id = Cyclium.AtomGuard.intern!(to_string(exp[:id] || exp["id"]))

      case expectation_to_opts(exp, default_strategy) do
        {:ok, opts} -> {:cont, {:ok, [{id, opts} | acc]}}
        {:error, reason} -> {:halt, {:error, {reason, id}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp expectation_to_opts(exp, default_strategy) do
    with {:ok, strategy} <- resolve_expectation_strategy(exp, default_strategy) do
      opts = if strategy, do: [strategy: strategy], else: []

      opts =
        case normalize_trigger(exp[:trigger] || exp["trigger"]) do
          nil -> opts
          trigger -> [{:trigger, trigger} | opts]
        end

      opts = if exp[:budget], do: [{:budget, exp[:budget]} | opts], else: opts

      opts =
        if exp[:log_strategy],
          do: [{:log_strategy, known_atom(exp[:log_strategy])} | opts],
          else: opts

      opts =
        if exp[:recovery_policy],
          do: [{:recovery_policy, known_atom(exp[:recovery_policy])} | opts],
          else: opts

      opts =
        if exp[:subject_key], do: [{:subject_key, to_atom(exp[:subject_key])} | opts], else: opts

      opts = if exp[:debounce_ms], do: [{:debounce_ms, exp[:debounce_ms]} | opts], else: opts
      opts = if exp[:cooldown_ms], do: [{:cooldown_ms, exp[:cooldown_ms]} | opts], else: opts
      {:ok, opts}
    end
  end

  # A per-expectation strategy names a registered template
  # (`Cyclium.Strategy.TemplateRegistry`), never an arbitrary module: a
  # definition row could otherwise point an expectation at any loaded module.
  # An in-process caller may still hand over a module directly.
  defp resolve_expectation_strategy(exp, default_strategy) do
    case exp[:strategy] || exp["strategy"] do
      nil ->
        {:ok, default_strategy}

      mod when is_atom(mod) ->
        {:ok, mod}

      template when is_binary(template) ->
        case Cyclium.Strategy.TemplateRegistry.resolve(template) do
          nil -> {:error, {:unknown_strategy_template, template}}
          mod -> {:ok, mod}
        end
    end
  end

  # log_strategy / recovery_policy take one of a few compile-time atoms; an
  # unknown value stays a string (and falls back to the default downstream)
  # rather than minting an atom.
  defp known_atom(val) when is_atom(val), do: val
  defp known_atom(val) when is_binary(val), do: Cyclium.AtomGuard.key(val)

  # subject_key must be an atom (the actor matches on it); one per expectation.
  defp to_atom(val) when is_atom(val), do: val
  defp to_atom(val) when is_binary(val), do: Cyclium.AtomGuard.intern!(val)

  # Normalize a trigger spec into the `{:schedule, ms}` / `{:event, type}` form
  # the actor expects. Tolerant of key shape (atom or string) AND value shape
  # (atom or string), since DB JSON decodes to atom keys with string values
  # (`%{type: "event", event_type: "..."}`) while in-process callers may pass
  # either. Returns `nil` for an unrecognized/absent trigger.
  defp normalize_trigger(trigger) when is_map(trigger) do
    case to_string(trigger[:type] || trigger["type"] || "") do
      "schedule" -> {:schedule, trigger[:interval_ms] || trigger["interval_ms"]}
      "event" -> {:event, trigger[:event_type] || trigger["event_type"]}
      _ -> nil
    end
  end

  defp normalize_trigger(_), do: nil

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

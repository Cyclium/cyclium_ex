defmodule Cyclium.Strategy.Template.Dispatch do
  @moduledoc """
  Data-driven strategy template: Gather entities → Broadcast events.

  Fan-out pattern. Calls a gatherer that returns a list of entities,
  then broadcasts a bus event for each entity to trigger downstream actors.

  ## Strategy config shape

      %{
        "gatherer" => "active_projects",
        "event_type" => "project_health.check_requested",
        "entity_id_field" => "id",
        "entity_payload_fields" => ["id", "name"]
      }

  The gatherer must return `{:ok, %{entities: [%{...}, ...]}}` where
  each entity is a map. The `entity_id_field` and `entity_payload_fields`
  control what gets broadcast.
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  require Logger

  alias Cyclium.ConvergeResult

  @impl true
  def init(episode, trigger) do
    strategy_config = load_strategy_config(episode.actor_id)
    trigger_payload = extract_trigger_payload(trigger)

    {:ok,
     %{
       phase: :gather,
       strategy_config: strategy_config,
       trigger_payload: trigger_payload,
       entities: [],
       dispatched: 0
     }}
  end

  @impl true
  def next_step(%{phase: :gather} = state, _episode_ctx) do
    gatherer_name = state.strategy_config["gatherer"]
    gatherer = Cyclium.Gatherer.resolve(gatherer_name)

    if gatherer do
      result =
        try do
          gatherer.gather(state.trigger_payload, state.strategy_config)
        catch
          kind, reason ->
            Logger.error(
              "[Dispatch] Gatherer #{gatherer_name} raised: #{inspect({kind, reason})}"
            )

            {:error, {kind, reason}}
        end

      case result do
        {:ok, %{entities: entities}} when is_list(entities) ->
          {:observe, %{entities: entities}}

        {:ok, data} when is_map(data) ->
          # Try to find a list in the data
          entities = find_entities(data)
          {:observe, %{entities: entities}}

        {:error, reason} ->
          Logger.error("[Dispatch] Gatherer #{gatherer_name} failed: #{inspect(reason)}")
          {:observe, %{entities: []}}
      end
    else
      Logger.error("[Dispatch] No gatherer registered as #{inspect(gatherer_name)}")
      {:observe, %{entities: []}}
    end
  end

  def next_step(%{phase: :dispatch, entities: []}, _episode_ctx), do: :converge

  def next_step(%{phase: :dispatch, entities: [entity | _]} = state, _episode_ctx) do
    config = state.strategy_config
    payload_fields = config["entity_payload_fields"] || Map.keys(entity)

    payload =
      entity
      |> Map.take(payload_fields)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    {:observe, %{action: "dispatch", entity: payload}}
  end

  def next_step(%{phase: :done}, _episode_ctx), do: :converge

  @impl true
  def handle_result(%{phase: :gather} = state, _step, {:ok, %{entities: entities}}) do
    {:ok, %{state | phase: :dispatch, entities: entities}}
  end

  def handle_result(%{phase: :dispatch} = state, _step, {:ok, %{entity: entity}}) do
    config = state.strategy_config
    event_type = config["event_type"]
    entity_id_field = config["entity_id_field"] || "id"

    if event_type do
      entity_payload =
        entity
        |> Map.put(
          entity_id_field,
          entity[entity_id_field] || entity[String.to_atom(entity_id_field)]
        )

      Cyclium.Bus.broadcast(event_type, entity_payload)
    end

    [_ | rest] = state.entities
    {:ok, %{state | entities: rest, dispatched: state.dispatched + 1}}
  end

  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, _episode_ctx) do
    {:ok,
     %ConvergeResult{
       classification: %{"primary" => "dispatch", "severity" => "low"},
       confidence: 1.0,
       summary: "Dispatched #{state.dispatched} events",
       findings: [],
       outputs: []
     }}
  end

  # --- Private ---

  defp load_strategy_config(actor_id) do
    import Ecto.Query

    case Cyclium.repo().one(
           from(d in Cyclium.Schemas.AgentDefinition,
             where: d.actor_id == ^to_string(actor_id),
             select: d.strategy_config
           )
         ) do
      nil -> %{}
      json when is_binary(json) -> Jason.decode!(json)
      config when is_map(config) -> config
    end
  rescue
    _ -> %{}
  end

  defp extract_trigger_payload(%Cyclium.Trigger.Event{payload: payload}) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string(k), v} end)
  end

  defp extract_trigger_payload(%{payload: payload}) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string(k), v} end)
  end

  defp extract_trigger_payload(_), do: %{}

  defp find_entities(data) when is_map(data) do
    # Look for the first list value in the data map
    Enum.find_value(data, [], fn
      {_k, v} when is_list(v) -> v
      _ -> nil
    end)
  end
end

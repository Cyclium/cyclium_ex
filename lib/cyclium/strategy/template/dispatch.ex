defmodule Cyclium.Strategy.Template.Dispatch do
  @moduledoc """
  Data-driven strategy template: Gather entities → Broadcast events.

  Fan-out pattern. Calls a gatherer that returns a list of entities,
  then broadcasts a bus event for each entity to trigger downstream actors.
  All gathering and broadcasting happens in `init` — no step loop needed.

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
    config = load_strategy_config(episode.actor_id)
    trigger_payload = extract_trigger_payload(trigger)

    entities = gather_entities(config, trigger_payload)

    if event_type = config["event_type"] do
      Enum.each(entities, fn entity ->
        Cyclium.Bus.broadcast(event_type, build_entity_payload(entity, config))
      end)
    else
      Logger.warning("Dispatch template has no event_type configured",
        template: "Dispatch",
        actor_id: episode.actor_id
      )
    end

    {:ok, %{dispatched: length(entities)}}
  end

  @impl true
  def next_step(_state, _episode_ctx), do: :converge

  @impl true
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

  defp gather_entities(config, trigger_payload) do
    gatherer_name = config["gatherer"]
    gatherer = Cyclium.Gatherer.resolve(gatherer_name)

    if gatherer do
      result =
        try do
          gatherer.gather(trigger_payload, config)
        catch
          kind, reason ->
            Logger.error("Gatherer raised: #{inspect({kind, reason})}",
              template: "Dispatch",
              gatherer: gatherer_name
            )

            {:error, {kind, reason}}
        end

      case result do
        {:ok, %{entities: entities}} when is_list(entities) ->
          entities

        {:ok, data} when is_map(data) ->
          find_entities(data)

        {:error, reason} ->
          Logger.error("Gatherer failed: #{inspect(reason)}",
            template: "Dispatch",
            gatherer: gatherer_name
          )

          []
      end
    else
      Logger.error("No gatherer registered as #{inspect(gatherer_name)}",
        template: "Dispatch",
        gatherer: gatherer_name
      )

      []
    end
  end

  defp build_entity_payload(entity, config) do
    payload_fields = config["entity_payload_fields"] || Map.keys(entity)

    entity
    |> Map.take(payload_fields)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

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
    Enum.find_value(data, [], fn
      {_k, v} when is_list(v) -> v
      _ -> nil
    end)
  end
end

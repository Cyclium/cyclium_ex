defmodule Cyclium.Strategy.Template.ObserveClassifyConverge do
  @moduledoc """
  Data-driven strategy template: Gather → Classify (rules) → Converge.

  Uses a named gatherer to collect data, then applies rule-based classification
  without LLM synthesis. Suitable for simple threshold/rule actors.

  ## Strategy config shape

      %{
        "gatherer" => "client_metrics",
        "classify_rules" => [
          %{"field" => "mrr", "op" => "lt", "value" => 500, "class" => "at_risk", "severity" => "high"},
          %{"field" => "last_login_days_ago", "op" => "gt", "value" => 30, "class" => "inactive", "severity" => "medium"}
        ],
        "default_class" => "healthy",
        "default_severity" => "low",
        "finding_config" => %{
          "actor_id_field" => "client_health_actor",
          "finding_key_template" => "client:health:${subject_id}",
          "subject_kind" => "client",
          "subject_id_key" => "client_id"
        }
      }

  ## Rule operators

  - `"lt"` — less than
  - `"gt"` — greater than
  - `"eq"` — equals
  - `"neq"` — not equals
  - `"in"` — value in list
  - `"not_in"` — value not in list

  Rules are evaluated in order. First match wins.
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
       gathered_data: nil,
       classification: nil
     }}
  end

  @impl true
  def next_step(%{phase: :gather} = state, _episode_ctx) do
    gatherer_name = state.strategy_config["gatherer"]
    gatherer = Cyclium.Gatherer.resolve(gatherer_name)

    if gatherer do
      case gatherer.gather(state.trigger_payload, state.strategy_config) do
        {:ok, data} ->
          {:observe, data}

        {:error, reason} ->
          Logger.error(
            "[ObserveClassifyConverge] Gatherer #{gatherer_name} failed: #{inspect(reason)}"
          )

          {:observe, %{_error: true, reason: inspect(reason)}}
      end
    else
      Logger.error(
        "[ObserveClassifyConverge] No gatherer registered as #{inspect(gatherer_name)}"
      )

      {:observe, %{_error: true, reason: "unknown_gatherer"}}
    end
  end

  def next_step(%{phase: :done}, _episode_ctx), do: :converge

  @impl true
  def handle_result(%{phase: :gather} = state, _step, {:ok, data}) do
    config = state.strategy_config
    rules = config["classify_rules"] || []
    default_class = config["default_class"] || "unknown"
    default_severity = config["default_severity"] || "low"

    {class, severity} = classify(data, rules, default_class, default_severity)

    {:ok,
     %{
       state
       | phase: :done,
         gathered_data: data,
         classification: %{"class" => class, "severity" => severity}
     }}
  end

  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, episode_ctx) do
    config = state.strategy_config
    finding_config = config["finding_config"] || %{}

    classification = state.classification || %{"class" => "error", "severity" => "low"}
    findings = build_findings(state, finding_config, classification, episode_ctx)

    summary = "Classified as #{classification["class"]} (#{classification["severity"]})"

    {:ok,
     %ConvergeResult{
       classification: %{
         "primary" => classification["class"],
         "severity" => classification["severity"]
       },
       confidence: 1.0,
       summary: summary,
       findings: findings,
       outputs: []
     }}
  end

  # --- Classification ---

  defp classify(data, rules, default_class, default_severity) do
    data_map = normalize_data(data)

    case Enum.find(rules, fn rule -> rule_matches?(rule, data_map) end) do
      %{"class" => class, "severity" => severity} -> {class, severity}
      %{"class" => class} -> {class, default_severity}
      _ -> {default_class, default_severity}
    end
  end

  defp normalize_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_string(k), v} end)
  end

  defp rule_matches?(%{"field" => field, "op" => op, "value" => expected}, data) do
    actual = Map.get(data, field)
    compare(op, actual, expected)
  end

  defp rule_matches?(_, _), do: false

  defp compare("lt", actual, expected) when is_number(actual) and is_number(expected),
    do: actual < expected

  defp compare("gt", actual, expected) when is_number(actual) and is_number(expected),
    do: actual > expected

  defp compare("eq", actual, expected), do: actual == expected
  defp compare("neq", actual, expected), do: actual != expected
  defp compare("in", actual, expected) when is_list(expected), do: actual in expected
  defp compare("not_in", actual, expected) when is_list(expected), do: actual not in expected
  defp compare(_, _, _), do: false

  # --- Finding builder ---

  defp build_findings(state, finding_config, classification, episode_ctx) do
    if state.gathered_data && !state.gathered_data[:_error] do
      actor_id_val = finding_config["actor_id_field"] || episode_ctx.actor_id
      subject_kind = finding_config["subject_kind"] || "unknown"
      subject_id_key = finding_config["subject_id_key"]

      subject_id =
        cond do
          subject_id_key && state.trigger_payload[subject_id_key] ->
            state.trigger_payload[subject_id_key]

          subject_id_key && is_map(state.gathered_data) ->
            state.gathered_data[subject_id_key] ||
              state.gathered_data[String.to_atom(subject_id_key)]

          true ->
            episode_ctx.episode_id
        end

      finding_key = build_finding_key(finding_config, subject_id, episode_ctx)

      severity =
        case classification["severity"] do
          s when is_atom(s) -> s
          s when is_binary(s) -> String.to_atom(s)
          _ -> :low
        end

      [
        {:raise,
         %{
           actor_id: to_string(actor_id_val),
           finding_key: finding_key,
           class: classification["class"],
           severity: severity,
           confidence: 1.0,
           subject: %{kind: subject_kind, id: subject_id},
           subject_kind: subject_kind,
           subject_id: subject_id,
           summary: "Classified as #{classification["class"]} (#{classification["severity"]})"
         }}
      ]
    else
      []
    end
  end

  defp build_finding_key(finding_config, subject_id, episode_ctx) do
    case finding_config["finding_key_template"] do
      nil ->
        "dynamic:#{episode_ctx.actor_id}:#{subject_id}"

      template ->
        template
        |> String.replace("${subject_id}", to_string(subject_id))
        |> String.replace("${actor_id}", to_string(episode_ctx.actor_id))
        |> String.replace("${episode_id}", to_string(episode_ctx.episode_id))
    end
  end

  # --- Shared helpers ---

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
end

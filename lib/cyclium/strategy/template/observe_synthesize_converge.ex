defmodule Cyclium.Strategy.Template.ObserveSynthesizeConverge do
  @moduledoc """
  Data-driven strategy template: Gather → Synthesize → Converge.

  The most common pattern for dynamic actors. A named gatherer collects
  domain data, an LLM synthesizer analyzes it, and the result is mapped
  to findings and outputs.

  ## Strategy config shape

      %{
        "gatherer" => "project_data",
        "system_prompt" => "You are a project health analyst...",
        "finding_config" => %{
          "actor_id_field" => "project_health_actor",
          "finding_key_template" => "project:health:${subject_id}",
          "class_field" => "class",
          "severity_field" => "severity",
          "summary_field" => "summary",
          "subject_kind" => "project",
          "subject_id_key" => "project_id"
        },
        "outputs" => ["email"]
      }
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  require Logger

  alias Cyclium.{ConvergeResult, OutputProposal}
  alias Cyclium.Strategy.Retry

  @impl true
  def init(episode, trigger) do
    strategy_config = load_strategy_config(episode.actor_id)
    trigger_payload = extract_trigger_payload(trigger)

    validate_output_adapters(strategy_config, episode.actor_id)

    {:ok,
     %{
       phase: :gather,
       strategy_config: strategy_config,
       trigger_payload: trigger_payload,
       gathered_data: nil,
       synthesis_result: nil
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
              "[ObserveSynthesizeConverge] Gatherer #{gatherer_name} raised: #{inspect({kind, reason})}"
            )

            {:error, {kind, reason}}
        end

      case result do
        {:ok, data} ->
          {:observe, data}

        {:error, reason} ->
          Logger.error(
            "[ObserveSynthesizeConverge] Gatherer #{gatherer_name} failed: #{inspect(reason)}"
          )

          {:observe, %{_error: true, reason: inspect(reason)}}
      end
    else
      Logger.error(
        "[ObserveSynthesizeConverge] No gatherer registered as #{inspect(gatherer_name)}"
      )

      {:observe, %{_error: true, reason: "unknown_gatherer"}}
    end
  end

  def next_step(%{phase: :synthesize} = state, _episode_ctx) do
    prompt_ctx =
      %{gathered_data: state.gathered_data}
      |> maybe_add_system_prompt(state.strategy_config)

    {:synthesize, prompt_ctx}
  end

  def next_step(%{phase: :done}, _episode_ctx), do: :converge

  @impl true
  def handle_result(%{phase: :gather} = state, _step, {:ok, data}) do
    if data[:_error] do
      {:ok, %{state | phase: :done, gathered_data: data}}
    else
      {:ok, %{state | phase: :synthesize, gathered_data: data}}
    end
  end

  def handle_result(%{phase: :synthesize} = state, _step, {:ok, result}) do
    {:ok,
     state
     |> Retry.reset(:synthesis)
     |> Map.put(:synthesis_result, result)
     |> Map.put(:phase, :done)}
  end

  def handle_result(
        %{phase: :synthesize} = state,
        %{kind: :synthesis} = step,
        {:error, {error_class, detail}}
      ) do
    Logger.warning(
      "[ObserveSynthesizeConverge] Synthesis error: #{error_class} — #{inspect(detail)}"
    )

    case Retry.check(state, step, max_attempts: 3, backoff_ms: 2_000) do
      {:retry, new_state} ->
        {:retry, new_state}

      {:give_up, attempts, new_state} ->
        Logger.error("[ObserveSynthesizeConverge] Synthesis failed after #{attempts} attempts")

        {:ok,
         %{
           new_state
           | synthesis_result: %{
               "_error" => true,
               "summary" => "LLM synthesis failed after #{attempts} attempts: #{error_class}"
             },
             phase: :done
         }}
    end
  end

  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, episode_ctx) do
    config = state.strategy_config
    finding_config = config["finding_config"] || %{}

    findings = build_findings(state, finding_config, episode_ctx)
    outputs = build_outputs(state, config, episode_ctx)

    summary =
      cond do
        state.synthesis_result && is_map(state.synthesis_result) ->
          summary_field = finding_config["summary_field"] || "summary"
          state.synthesis_result[summary_field] || inspect(state.synthesis_result)

        state.gathered_data && state.gathered_data[:_error] ->
          "Gather phase failed: #{state.gathered_data[:reason]}"

        true ->
          "No synthesis result"
      end

    classification =
      if state.synthesis_result && is_map(state.synthesis_result) do
        class_field = finding_config["class_field"] || "class"
        severity_field = finding_config["severity_field"] || "severity"

        %{
          "primary" => state.synthesis_result[class_field] || "unknown",
          "severity" => to_string(state.synthesis_result[severity_field] || "low")
        }
      else
        %{"primary" => "error", "severity" => "low"}
      end

    confidence =
      if state.synthesis_result && is_map(state.synthesis_result) do
        state.synthesis_result["confidence"] || 0.5
      else
        0.0
      end

    {:ok,
     %ConvergeResult{
       classification: classification,
       confidence: confidence,
       summary: summary,
       findings: findings,
       outputs: outputs
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
      nil ->
        %{}

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, config} -> config
          _ -> %{}
        end

      config when is_map(config) ->
        config
    end
  rescue
    _ -> %{}
  end

  defp extract_trigger_payload(%Cyclium.Trigger.Event{payload: payload}) when is_map(payload) do
    stringify_keys(payload)
  end

  defp extract_trigger_payload(%{payload: payload}) when is_map(payload) do
    stringify_keys(payload)
  end

  defp extract_trigger_payload(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_add_system_prompt(prompt_ctx, %{"system_prompt" => prompt}) when is_binary(prompt) do
    Map.put(prompt_ctx, :system_prompt, prompt)
  end

  defp maybe_add_system_prompt(prompt_ctx, _), do: prompt_ctx

  defp build_findings(state, finding_config, episode_ctx) do
    result = state.synthesis_result

    if result && is_map(result) && !result["_error"] do
      actor_id_val = finding_config["actor_id_field"] || episode_ctx.actor_id
      subject_kind = finding_config["subject_kind"] || "unknown"
      subject_id_key = finding_config["subject_id_key"]
      class_field = finding_config["class_field"] || "class"
      severity_field = finding_config["severity_field"] || "severity"
      summary_field = finding_config["summary_field"] || "summary"

      subject_id =
        cond do
          subject_id_key && state.trigger_payload[subject_id_key] ->
            state.trigger_payload[subject_id_key]

          subject_id_key && state.gathered_data && is_map(state.gathered_data) ->
            state.gathered_data[subject_id_key] ||
              state.gathered_data[String.to_atom(subject_id_key)]

          true ->
            episode_ctx.episode_id
        end

      finding_key = build_finding_key(finding_config, subject_id, episode_ctx)

      severity =
        case result[severity_field] do
          s when is_atom(s) -> s
          s when is_binary(s) -> String.to_atom(s)
          _ -> :low
        end

      [
        {:raise,
         %{
           actor_id: to_string(actor_id_val),
           finding_key: finding_key,
           class: result[class_field] || "unknown",
           severity: severity,
           confidence: result["confidence"] || 0.5,
           subject: %{kind: subject_kind, id: subject_id},
           subject_kind: subject_kind,
           subject_id: subject_id,
           summary: result[summary_field] || inspect(result),
           evidence_refs:
             Map.drop(result, [class_field, severity_field, summary_field, "confidence"])
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

  defp build_outputs(_state, %{"outputs" => output_types}, episode_ctx)
       when is_list(output_types) do
    Enum.map(output_types, fn type ->
      %OutputProposal{
        type: String.to_atom(type),
        dedupe_key: "dynamic:#{episode_ctx.actor_id}:#{episode_ctx.episode_id}:#{type}",
        payload: %{episode_id: episode_ctx.episode_id, actor_id: episode_ctx.actor_id}
      }
    end)
  end

  defp build_outputs(_, _, _), do: []

  defp validate_output_adapters(%{"outputs" => types}, actor_id) when is_list(types) do
    Enum.each(types, fn type ->
      unless Cyclium.Output.Adapter.resolve(type) do
        Logger.warning(
          "[ObserveSynthesizeConverge] Actor #{actor_id}: output type #{inspect(type)} has no registered adapter"
        )
      end
    end)
  end

  defp validate_output_adapters(_, _), do: :ok
end

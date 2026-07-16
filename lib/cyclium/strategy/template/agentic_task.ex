defmodule Cyclium.Strategy.Template.AgenticTask do
  @moduledoc """
  Strategy template for an **autonomous, tool-calling episode** — the same
  interpret → validate → execute → summarize loop as
  `Cyclium.Strategy.Template.Interactive`, but with no human in the loop.

  Instead of a conversation turn, the run is seeded from an **objective** and the
  triggering payload; the LLM then plans, calls tools as it sees fit (bounded by
  `allowed_tool_signatures`), and terminates by calling the reserved
  `finish_agentic_task` tool with its conclusion. The episode converges to
  findings and/or outputs.

      context_assembly → interpret → validate → [preview] → execute → summarize
                                        ↑__________________________________|
                               (loop until the model calls finish_agentic_task)

  ## Objective (static + payload)

  The objective is a template string, interpolated against the trigger payload
  with `{{key}}` / `{{a.b}}` placeholders:

      strategy_config: %{
        objective: "Review resource {{resource_id}} for over-allocation and raise a finding if it is over limit.",
        role: "You are an operations analyst.",
        guidelines: ["Use read tools to gather evidence before concluding."],
        allowed_tool_signatures: [ ... ]
      }

  A trigger payload may also carry its own `"objective"` string, which takes
  precedence over the static template (still interpolated against the payload).

  ## Termination

  The reserved `finish_agentic_task` tool is auto-injected into the tool menu
  (the app does not declare it). Calling it ends the run; its args become the
  converge result:

      {"tool": "finish_agentic_task", "action": "finish_agentic_task", "args": {
        "summary": "...",
        "confidence": 0.9,
        "findings": [{"action": "raise", "class": "over_limit", "summary": "...", ...}],
        "outputs":  [{"type": "slack", "dedupe_key": "...", "payload": {...}}]
      }}

  If the model instead stops with a plain-text answer (`explain_only`), that text
  becomes the summary and the episode converges without findings.

  ## Security

  With no human preview by default, `allowed_tool_signatures` is the entire
  security boundary — keep it as narrow as the task needs, and prefer read-only
  signatures unless a write is genuinely required. See the interactive-actors
  guide's Security section; the same reasoning applies here.
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  alias Cyclium.ConvergeResult
  alias Cyclium.Strategy.Template.Agentic.Loop

  # --- Strategy callbacks ---

  @impl true
  def init(episode, trigger) do
    payload = trigger_payload(trigger)

    strategy_config =
      episode.actor_id
      |> Loop.load_strategy_config()
      |> Map.put_new("actor_id", to_string(episode.actor_id))
      |> Loop.with_finish_tool()
      |> ensure_finish_guideline()

    objective = resolve_objective(strategy_config, payload)

    {:ok,
     %{
       phase: :context_assembly,
       strategy_config: strategy_config,
       message: objective,
       payload: payload,
       gathered_context: nil,
       action_plan: nil,
       plan_hash: nil,
       execution_results: [],
       current_step_index: 0,
       deny_reason: nil,
       explanation: nil,
       conclusion: nil,
       budget_exhausted: false
     }}
  end

  @impl true
  def next_step(%{phase: :context_assembly} = state, episode_ctx) do
    {:observe, assemble_context(state, episode_ctx)}
  end

  def next_step(state, episode_ctx), do: Loop.next_step(state, episode_ctx)

  @impl true
  def handle_result(%{phase: :context_assembly} = state, _step, {:ok, context}) do
    {:ok, %{state | phase: :interpret, gathered_context: context}}
  end

  def handle_result(state, step, result), do: Loop.handle_result(state, step, result)

  @impl true
  def converge(state, _episode_ctx) do
    cond do
      state[:budget_exhausted] ->
        result(Loop.budget_exhausted_summary(state), %{
          "primary" => "incomplete",
          "reason" => "budget_exhausted"
        })

      state.deny_reason ->
        result("Task blocked: #{state.deny_reason}", %{
          "primary" => "denied",
          "reason" => state.deny_reason
        })

      is_map(state[:conclusion]) ->
        c = state.conclusion

        {:ok,
         %ConvergeResult{
           summary: c["summary"] || Loop.build_execution_summary(state),
           classification: %{"primary" => "task_complete", "terminal" => "finish"},
           confidence: parse_confidence(c["confidence"]),
           findings: Loop.build_findings_list(c["findings"]),
           outputs: Loop.build_outputs_list(c["outputs"])
         }}

      is_binary(state[:explanation]) and state.explanation != "" ->
        # Model answered with plain text instead of calling `finish_agentic_task`.
        {:ok,
         %ConvergeResult{
           summary: state.explanation,
           classification: %{"primary" => "task_complete", "terminal" => "explanation"},
           confidence: 0.7,
           findings: [],
           outputs: []
         }}

      true ->
        result(Loop.build_execution_summary(state), %{"primary" => "no_action"})
    end
  end

  @impl true
  def workflow_result(_state, converge_result) do
    %{
      summary: converge_result.summary,
      classification: converge_result.classification
    }
  end

  @impl true
  def handle_budget_exhausted(state, episode_ctx),
    do: Loop.handle_budget_exhausted(state, episode_ctx)

  @impl true
  def resume_from_block(state, episode), do: Loop.resume_from_block(state, episode)

  # --- Context assembly ---

  defp assemble_context(state, episode_ctx) do
    %{
      objective: state.message,
      payload: state.payload,
      findings: load_relevant_findings(episode_ctx),
      actor_id: episode_ctx.actor_id
    }
  end

  defp load_relevant_findings(episode_ctx) do
    Cyclium.Findings.active_for(actor: episode_ctx.actor_id)
  rescue
    _ -> []
  end

  # --- Objective interpolation ---

  defp resolve_objective(strategy_config, payload) do
    template =
      cond do
        is_binary(payload["objective"]) and payload["objective"] != "" -> payload["objective"]
        is_binary(strategy_config["objective"]) -> strategy_config["objective"]
        true -> "Complete the assigned task."
      end

    interpolate(template, payload)
  end

  # Replace {{key}} / {{a.b}} placeholders with values from the payload. An
  # unresolved key becomes an empty string rather than raising, so a partially
  # populated payload degrades gracefully.
  defp interpolate(template, payload) when is_binary(template) do
    Regex.replace(~r/\{\{\s*([\w.]+)\s*\}\}/, template, fn _match, path ->
      to_string(get_in_payload(payload, path))
    end)
  end

  defp get_in_payload(payload, path) do
    path
    |> String.split(".")
    |> Enum.reduce(payload, fn
      _key, acc when not is_map(acc) -> nil
      key, acc -> acc[key] || acc[safe_existing_atom(key)]
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # --- Trigger payload extraction ---

  defp trigger_payload(%Cyclium.Trigger.Event{payload: payload}) when is_map(payload),
    do: stringify_keys(payload)

  defp trigger_payload(%Cyclium.Trigger.Workflow{input: input}) when is_map(input),
    do: stringify_keys(input)

  defp trigger_payload(%Cyclium.Trigger.Manual{requested_by: rb, reason: reason}),
    do: %{"requested_by" => rb, "reason" => reason}

  defp trigger_payload(%Cyclium.Trigger.Schedule{scheduled_at: at}),
    do: %{"scheduled_at" => at}

  defp trigger_payload(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # --- Converge helpers ---

  defp result(summary, classification) do
    {:ok,
     %ConvergeResult{
       summary: summary,
       classification: classification,
       confidence: 0.5,
       findings: [],
       outputs: []
     }}
  end

  defp parse_confidence(val) when is_number(val), do: max(0.0, min(val * 1.0, 1.0))

  defp parse_confidence(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> parse_confidence(num)
      :error -> 0.8
    end
  end

  defp parse_confidence(_), do: 0.8

  # Nudge the model to end with `finish_agentic_task` unless the app already said so.
  defp ensure_finish_guideline(strategy_config) do
    guidelines = strategy_config["guidelines"] || []

    if Enum.any?(guidelines, &String.contains?(to_string(&1), "finish_agentic_task")) do
      strategy_config
    else
      Map.put(
        strategy_config,
        "guidelines",
        guidelines ++
          [
            "When the objective is complete, call the finish_agentic_task tool with your summary and any findings."
          ]
      )
    end
  end
end

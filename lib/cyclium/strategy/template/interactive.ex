defmodule Cyclium.Strategy.Template.Interactive do
  @moduledoc """
  Strategy template for interactive actors. Implements the intent interpretation loop:

  1. context_assembly — gather context for the synthesizer
  2. interpret — call synthesizer with structured output spec
  3. validate — run plan through PlanGate
  4. preview (conditional) — block for approval if side effects
  5. execute — run the plan
  6. converge — standard converge with findings, outputs, summary

  Uses Option A from the plan: one episode per conversation turn.
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  require Logger

  alias Cyclium.{ConvergeResult, OutputProposal, Conversations}

  alias Cyclium.Intent.{
    ActionPlan,
    PlanGate,
    GoalSpec,
    SignatureMatcher,
    ToolCallStep
  }

  alias Cyclium.Strategy.Retry

  # --- Strategy callbacks ---

  @impl true
  def init(episode, %Cyclium.Trigger.Interactive{} = trigger) do
    strategy_config = load_strategy_config(episode.actor_id)
    conversation = load_conversation(episode.conversation_id)
    goal = if conversation, do: Cyclium.Schemas.Conversation.decode_goal(conversation)

    {:ok,
     %{
       phase: :context_assembly,
       strategy_config: strategy_config,
       message: trigger.message,
       principal: trigger.principal,
       history: trigger.history,
       conversation_id: trigger.conversation_id,
       conversation: conversation,
       goal: goal && struct(GoalSpec, atomize_keys(goal)),
       gathered_context: nil,
       action_plan: nil,
       plan_hash: nil,
       execution_results: [],
       current_step_index: 0,
       deny_reason: nil,
       explanation: nil,
       budget_exhausted: false
     }}
  end

  def init(_episode, _trigger) do
    # Fallback for non-interactive triggers (shouldn't happen but be safe)
    {:ok, %{phase: :done, strategy_config: %{}, explanation: "Non-interactive trigger"}}
  end

  @impl true
  def next_step(%{phase: :context_assembly} = state, episode_ctx) do
    context = assemble_context(state, episode_ctx)
    {:observe, context}
  end

  def next_step(%{phase: :interpret} = state, _episode_ctx) do
    prompt_ctx = build_interpret_prompt(state)
    {:synthesize, prompt_ctx}
  end

  def next_step(%{phase: :validate} = state, _episode_ctx) do
    # Validation is synchronous — run it here and transition via :observe (which
    # journals the decision as an observation step).
    case PlanGate.evaluate(state.action_plan, build_policy_ctx(state), state.strategy_config) do
      :ok ->
        if should_preview?(state) do
          {:observe, %{validated: true, next_phase: :preview}}
        else
          {:observe, %{validated: true, next_phase: :execute}}
        end

      {:deny, reason} ->
        {:observe, %{denied: true, reason: reason}}
    end
  end

  def next_step(%{phase: :preview} = state, _episode_ctx) do
    plan_data = serialize_plan(state.action_plan)

    {:approval,
     %{plan_hash: state.plan_hash, plan: plan_data, reason: "Side-effect plan requires approval"}}
  end

  def next_step(%{phase: :execute} = state, _episode_ctx) do
    execute_next_action(state)
  end

  def next_step(%{phase: :summarize} = state, _episode_ctx) do
    prompt_ctx = build_summarize_prompt(state)
    {:synthesize, prompt_ctx}
  end

  def next_step(%{phase: :denied}, _episode_ctx), do: :converge
  def next_step(%{phase: :done}, _episode_ctx), do: :converge

  @impl true
  def handle_result(%{phase: :context_assembly} = state, _step, {:ok, context}) do
    {:ok, %{state | phase: :interpret, gathered_context: context}}
  end

  def handle_result(%{phase: :interpret} = state, _step, {:ok, result}) do
    case parse_action_plan(result) do
      {:ok, plan} ->
        hash = :erlang.phash2(plan) |> Integer.to_string()
        {:ok, %{state | phase: :validate, action_plan: plan, plan_hash: hash}}

      {:error, reason} ->
        Logger.warning("Failed to parse action plan: #{inspect(reason)}",
          template: "Interactive"
        )

        {:ok,
         %{state | phase: :done, explanation: "Failed to interpret intent: #{inspect(reason)}"}}
    end
  end

  def handle_result(
        %{phase: :interpret} = state,
        %{kind: :synthesis} = step,
        {:error, {error_class, _detail}}
      ) do
    case Retry.check(state, step, max_attempts: 2, backoff_ms: 1_000) do
      {:retry, new_state} ->
        {:retry, new_state}

      {:give_up, _attempts, new_state} ->
        {:ok, %{new_state | phase: :done, explanation: "Synthesis failed: #{error_class}"}}
    end
  end

  def handle_result(%{phase: :validate} = state, _step, {:ok, %{denied: true, reason: reason}}) do
    {:ok, %{state | phase: :denied, deny_reason: reason}}
  end

  def handle_result(
        %{phase: :validate} = state,
        _step,
        {:ok, %{validated: true, next_phase: :preview}}
      ) do
    {:ok, %{state | phase: :preview}}
  end

  def handle_result(
        %{phase: :validate} = state,
        _step,
        {:ok, %{validated: true, next_phase: :execute}}
      ) do
    {:ok, %{state | phase: :execute, current_step_index: 0}}
  end

  def handle_result(%{phase: :preview} = state, _step, {:ok, %{approved: true}}) do
    {:ok, %{state | phase: :execute, current_step_index: 0}}
  end

  def handle_result(%{phase: :preview} = state, _step, {:ok, %{approved: false}}) do
    {:ok, %{state | phase: :denied, deny_reason: "Plan rejected by user"}}
  end

  def handle_result(%{phase: :execute} = state, _step, result) do
    results = state.execution_results ++ [result]
    next_idx = state.current_step_index + 1

    case state.action_plan.kind do
      :multi_tool_plan when next_idx < length(state.action_plan.steps) ->
        {:ok, %{state | execution_results: results, current_step_index: next_idx}}

      kind when kind in [:tool_call, :multi_tool_plan] ->
        # After tool execution, summarize results via LLM before converging
        {:ok, %{state | phase: :summarize, execution_results: results}}

      _ ->
        {:ok, %{state | phase: :done, execution_results: results}}
    end
  end

  def handle_result(%{phase: :summarize} = state, _step, {:ok, result}) do
    case parse_action_plan(result) do
      {:ok, %{kind: :tool_call} = plan} ->
        # LLM wants to make a follow-up tool call — loop back through validate → execute
        hash = :erlang.phash2(plan) |> Integer.to_string()

        {:ok,
         %{state | phase: :validate, action_plan: plan, plan_hash: hash, current_step_index: 0}}

      {:ok, %{kind: :explain_only, explanation: text}} when is_binary(text) ->
        {:ok, %{state | phase: :done, explanation: text}}

      {:ok, %{explanation: text}} when is_binary(text) ->
        {:ok, %{state | phase: :done, explanation: text}}

      _ ->
        explanation =
          case result do
            %{"explanation" => value} -> coerce_explanation(value)
            %{explanation: value} -> coerce_explanation(value)
            other -> coerce_explanation(other)
          end

        {:ok, %{state | phase: :done, explanation: explanation}}
    end
  end

  def handle_result(%{phase: :summarize} = state, _step, {:error, _}) do
    # If summarization fails, fall back to technical summary
    {:ok, %{state | phase: :done}}
  end

  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, episode_ctx) do
    plan = state.action_plan

    {summary, classification} =
      cond do
        state[:budget_exhausted] ->
          {budget_exhausted_summary(state),
           %{"primary" => "incomplete", "reason" => "budget_exhausted"}}

        state.deny_reason ->
          {"Plan denied: #{state.deny_reason}",
           %{"primary" => "denied", "reason" => state.deny_reason}}

        plan && plan.kind == :explain_only ->
          {plan.explanation || state.explanation || "Explanation provided",
           %{"primary" => "explain_only"}}

        plan ->
          summary = state.explanation || build_execution_summary(state)
          {summary, %{"primary" => to_string(plan.kind), "risk" => to_string(plan.risk)}}

        true ->
          {state.explanation || "No action taken", %{"primary" => "no_action"}}
      end

    outputs = build_outputs(state, episode_ctx)
    findings = build_findings(state)

    # Check for conversation resolution signals
    classification =
      if plan && plan.meta["resolve_conversation"] do
        Map.merge(classification, %{
          "conversation_resolved" => true,
          "outcome" => plan.meta["outcome"] || "completed",
          "result" => plan.meta["result"] || %{}
        })
      else
        classification
      end

    # Merge collected fields if present
    classification =
      if plan && plan.meta["collected_fields"] do
        Map.put(classification, "collected_fields", plan.meta["collected_fields"])
      else
        classification
      end

    {:ok,
     %ConvergeResult{
       summary: summary,
       classification: classification,
       confidence: (plan && plan.meta["confidence"]) || 0.8,
       outputs: outputs,
       findings: findings
     }}
  end

  @impl true
  def workflow_result(state, converge_result) do
    %{
      summary: converge_result.summary,
      classification: converge_result.classification,
      conversation_id: state.conversation_id
    }
  end

  @impl true
  def handle_budget_exhausted(state, _episode_ctx) do
    # Converge with an "out of budget" summary instead of failing. Map.put keeps
    # this safe for states resumed from a pre-:budget_exhausted checkpoint.
    {:converge, Map.put(%{state | phase: :done}, :budget_exhausted, true)}
  end

  @impl true
  def resume_from_block(state, episode) do
    # Resumed after a human resolved an approval. Rebuild the approved plan from
    # the journal (no state checkpoint) and jump to :execute/:denied so we run
    # exactly what was approved — no extra LLM round-trip or re-prompt.
    case latest_approval(episode.id) do
      {:ok, plan, plan_hash, true} ->
        {:ok,
         %{
           state
           | phase: :execute,
             action_plan: deserialize_plan(plan),
             plan_hash: plan_hash,
             current_step_index: 0,
             execution_results: []
         }}

      {:ok, _plan, _plan_hash, false} ->
        {:ok, %{state | phase: :denied, deny_reason: "Plan rejected by user"}}

      :none ->
        {:ok, state}
    end
  end

  # Find the most recent approval_requested step and its matching resolution.
  # Compares plan_hash in Elixir (not via a DB-specific JSON path) so this stays
  # adapter-agnostic; resolve_approval/3 already guarantees a resolution only
  # exists for a requested plan_hash.
  defp latest_approval(episode_id) do
    import Ecto.Query
    alias Cyclium.Schemas.EpisodeStep

    latest = fn kind ->
      from(s in EpisodeStep,
        where: s.episode_id == ^episode_id and s.kind == ^kind,
        order_by: [desc: s.step_no],
        limit: 1
      )
      |> Cyclium.repo().one()
    end

    with %{args_redacted: %{"plan_hash" => hash, "plan" => plan}} <- latest.(:approval_requested),
         %{result_ref: %{"approved" => approved, "plan_hash" => ^hash}} <-
           latest.(:approval_resolved) do
      {:ok, plan, hash, approved}
    else
      _ -> :none
    end
  end

  # Inverse of serialize_plan/1 for the subset we journal. String-keyed maps
  # (from the JSON round-trip) back into the structs the execute phase needs.
  defp deserialize_plan(%{} = plan) do
    %ActionPlan{
      kind: existing_atom(plan["kind"], :tool_call),
      risk: existing_atom(plan["risk"], :low),
      why: plan["why"] || "",
      tool: deserialize_tool(plan["tool"]),
      steps:
        plan |> Map.get("steps", []) |> Enum.map(&deserialize_tool/1) |> Enum.reject(&is_nil/1),
      meta: %{}
    }
  end

  defp deserialize_tool(%{} = tool) do
    %ToolCallStep{tool: tool["tool"], action: tool["action"], args: tool["args"] || %{}}
    |> split_dotted_tool()
  end

  defp deserialize_tool(_), do: nil

  defp existing_atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end

  defp existing_atom(_value, default), do: default

  # --- Private: Context assembly ---

  defp assemble_context(state, episode_ctx) do
    findings = load_relevant_findings(state, episode_ctx)
    prior_summaries = load_prior_episode_summaries(state)
    collected = load_collected_fields(state)

    %{
      message: state.message,
      principal: state.principal,
      history: state.history,
      findings: findings,
      prior_summaries: prior_summaries,
      goal: state.goal,
      collected_fields: collected,
      actor_id: episode_ctx.actor_id,
      conversation_id: state.conversation_id
    }
  end

  defp load_relevant_findings(_state, episode_ctx) do
    try do
      Cyclium.Findings.active_for(actor: episode_ctx.actor_id)
    rescue
      _ -> []
    end
  end

  defp load_prior_episode_summaries(%{conversation_id: nil}), do: []

  defp load_prior_episode_summaries(%{conversation_id: conv_id}) do
    import Ecto.Query

    from(e in Cyclium.Schemas.Episode,
      where: e.conversation_id == ^conv_id and e.status == :done,
      order_by: [asc: e.started_at],
      select: %{summary: e.summary, classification: e.classification, started_at: e.started_at},
      limit: 20
    )
    |> Cyclium.repo().all()
  rescue
    _ -> []
  end

  defp load_collected_fields(%{conversation: nil}), do: %{}

  defp load_collected_fields(%{conversation: conv}) do
    Cyclium.Schemas.Conversation.decode_collected_fields(conv)
  end

  # --- Private: Interpretation ---

  defp build_interpret_prompt(state) do
    allowed_outputs = state.strategy_config["allowed_output_types"] || []

    %{
      task: :interpret_intent,
      message: state.message,
      context: state.gathered_context,
      tool_menu: tool_menu_from_config(state.strategy_config),
      tool_mode: state.strategy_config["tool_mode"],
      allowed_output_types: allowed_outputs,
      goal: state.goal,
      system_prompt: Cyclium.Synthesizer.PromptBuilder.build(state.strategy_config)
    }
  end

  # Tool signatures reshaped into the synthesizer's tool menu. Shared by the
  # interpret and summarize prompts so the native path can offer the same tools
  # on a follow-up call.
  defp tool_menu_from_config(strategy_config) do
    (strategy_config["allowed_tool_signatures"] || [])
    |> Enum.map(fn sig ->
      %{
        name: sig["name"],
        side_effect: sig["side_effect"],
        constraints: sig["constraints"],
        actions: sig["actions"]
      }
    end)
  end

  defp build_summarize_prompt(state) do
    results_text =
      state.execution_results
      |> Enum.map(fn
        {:ok, data} -> inspect(data, pretty: true, limit: 500)
        {:error, reason} -> "Error: #{inspect(reason)}"
        other -> inspect(other, pretty: true, limit: 500)
      end)
      |> Enum.join("\n---\n")

    tool_desc =
      case state.action_plan.kind do
        :tool_call -> "#{state.action_plan.tool.tool}.#{state.action_plan.tool.action}"
        :multi_tool_plan -> "#{length(state.action_plan.steps)} tool calls"
        _ -> "action"
      end

    %{
      task: :summarize_results,
      message: state.message,
      tool_menu: tool_menu_from_config(state.strategy_config),
      tool_mode: state.strategy_config["tool_mode"],
      context: %{
        tool_executed: tool_desc,
        tool_results: results_text
      },
      system_prompt: Cyclium.Synthesizer.PromptBuilder.build(state.strategy_config)
    }
  end

  defp parse_action_plan(result) when is_map(result) do
    kind = parse_plan_kind(result["kind"] || result[:kind])
    risk = parse_risk(result["risk"] || result[:risk] || "low")
    why = result["why"] || result[:why] || ""

    plan = %ActionPlan{
      kind: kind,
      risk: risk,
      why: why,
      tool: parse_tool_call(result["tool"] || result[:tool]),
      steps: parse_tool_steps(result["steps"] || result[:steps] || []),
      output: parse_output(result["output"] || result[:output]),
      explanation: coerce_explanation(result["explanation"] || result[:explanation]),
      workflow: parse_workflow(result["workflow"] || result[:workflow]),
      approval: result["approval"] || result[:approval],
      meta: result["meta"] || result[:meta] || %{}
    }

    {:ok, plan}
  rescue
    e -> {:error, e}
  end

  defp parse_plan_kind("tool_call"), do: :tool_call
  defp parse_plan_kind("multi_tool_plan"), do: :multi_tool_plan
  defp parse_plan_kind("output_proposal"), do: :output_proposal
  defp parse_plan_kind("explain_only"), do: :explain_only
  defp parse_plan_kind("request_approval"), do: :request_approval
  defp parse_plan_kind("workflow_trigger"), do: :workflow_trigger
  defp parse_plan_kind(atom) when is_atom(atom), do: atom
  defp parse_plan_kind(_), do: :explain_only

  defp parse_risk("low"), do: :low
  defp parse_risk("medium"), do: :medium
  defp parse_risk("high"), do: :high
  defp parse_risk(atom) when is_atom(atom), do: atom
  defp parse_risk(_), do: :low

  defp parse_tool_call(nil), do: nil

  defp parse_tool_call(tc) when is_map(tc) do
    %ToolCallStep{
      tool: tc["tool"] || tc[:tool],
      action: tc["action"] || tc[:action],
      args: tc["args"] || tc[:args] || %{}
    }
    |> split_dotted_tool()
  end

  # Models (notably gpt-5) sometimes merge tool + action into a single dotted
  # name — `"episode_query.list_episodes"` — leaving `action` blank. The plan
  # gate then matches no signature ("not in allowed signatures"). Split it at
  # parse time so the signature matcher and executor see a clean tool + action;
  # done here rather than by loosening the matcher.
  defp split_dotted_tool(%ToolCallStep{tool: tool, action: action} = tc)
       when is_binary(tool) and (is_nil(action) or action == "") do
    case String.split(tool, ".", parts: 2) do
      [t, a] when a != "" -> %{tc | tool: t, action: a}
      _ -> tc
    end
  end

  defp split_dotted_tool(tc), do: tc

  # An `explanation` must be a plain string, but models sometimes over-structure
  # it (a nested object/array — gpt-5.2 returned a nested ActionPlan) or emit a
  # non-string. Coerce to text so a misformatted payload degrades gracefully
  # instead of leaking an inspected blob to the user. `nil` is preserved so the
  # downstream `plan.explanation || ...` fallback chain still fires.
  defp coerce_explanation(nil), do: nil
  defp coerce_explanation(text) when is_binary(text), do: text
  defp coerce_explanation(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp coerce_explanation(other), do: to_string(other)

  defp parse_tool_steps(steps) when is_list(steps) do
    Enum.map(steps, &parse_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_tool_steps(_), do: []

  defp parse_output(nil), do: nil

  defp parse_output(o) when is_map(o) do
    %OutputProposal{
      type: Cyclium.AtomGuard.intern!(o["type"] || to_string(o[:type] || "unknown")),
      dedupe_key: o["dedupe_key"] || o[:dedupe_key] || "",
      payload: o["payload"] || o[:payload] || %{},
      requires_approval: o["requires_approval"] || o[:requires_approval] || false
    }
  end

  defp parse_workflow(nil), do: nil

  defp parse_workflow(wf) when is_map(wf) do
    %Cyclium.Intent.WorkflowTrigger{
      workflow_id: wf["workflow_id"] || wf[:workflow_id],
      input: wf["input"] || wf[:input] || %{},
      purpose: wf["purpose"] || wf[:purpose]
    }
  end

  # --- Private: Validation helpers ---

  defp build_policy_ctx(state) do
    %{
      principal: state.principal,
      conversation_id: state.conversation_id,
      actor_id: state.strategy_config["actor_id"],
      goal: state.goal
    }
  end

  defp should_preview?(state) do
    require_preview = state.strategy_config["require_preview_for_side_effects"] || false
    plan = state.action_plan

    if require_preview and plan do
      signatures = parse_signatures(state.strategy_config)

      case plan.kind do
        :tool_call ->
          SignatureMatcher.has_side_effects?([plan.tool], signatures)

        :multi_tool_plan ->
          SignatureMatcher.has_side_effects?(plan.steps, signatures)

        :output_proposal ->
          true

        :workflow_trigger ->
          true

        _ ->
          false
      end
    else
      false
    end
  end

  defp parse_signatures(%{"allowed_tool_signatures" => sigs}) when is_list(sigs) do
    Enum.map(sigs, fn sig ->
      %Cyclium.Intent.ToolSignature{
        name: sig["name"],
        version: sig["version"] || 1,
        side_effect: parse_side_effect(sig["side_effect"]),
        constraints: sig["constraints"] || %{}
      }
    end)
  end

  defp parse_signatures(_), do: []

  defp parse_side_effect("read"), do: :read
  defp parse_side_effect("write"), do: :write
  defp parse_side_effect("external_effect"), do: :external_effect
  defp parse_side_effect(atom) when is_atom(atom), do: atom
  defp parse_side_effect(_), do: :read

  # --- Private: Execution ---

  defp execute_next_action(state) do
    plan = state.action_plan

    case plan.kind do
      :tool_call ->
        tc = plan.tool

        {:tool_call, Cyclium.AtomGuard.intern!(tc.tool), Cyclium.AtomGuard.intern!(tc.action),
         tc.args}

      :multi_tool_plan ->
        step = Enum.at(plan.steps, state.current_step_index)

        {:tool_call, Cyclium.AtomGuard.intern!(step.tool), Cyclium.AtomGuard.intern!(step.action),
         step.args}

      :output_proposal ->
        {:output, plan.output.type, plan.output.payload}

      :explain_only ->
        :converge

      :workflow_trigger ->
        wf = plan.workflow
        opts = if state.conversation_id, do: [conversation_id: state.conversation_id], else: []

        result =
          try do
            Cyclium.WorkflowEngine.start_dynamic_workflow(
              Cyclium.WorkflowEngine,
              wf.workflow_id,
              wf.input,
              opts
            )
          rescue
            _ -> {:error, :workflow_engine_unavailable}
          end

        case result do
          {:ok, instance_id} ->
            {:observe,
             %{workflow_triggered: true, workflow_id: wf.workflow_id, instance_id: instance_id}}

          {:error, reason} ->
            {:observe,
             %{workflow_triggered: false, workflow_id: wf.workflow_id, error: inspect(reason)}}
        end

      :request_approval ->
        {:approval, plan.approval}
    end
  end

  # --- Private: Converge helpers ---

  defp budget_exhausted_summary(state) do
    base = "I wasn't able to finish this request within the allotted budget for this turn."

    cond do
      is_binary(state.explanation) and state.explanation != "" ->
        base <> " Progress so far: " <> state.explanation

      state.execution_results != [] ->
        base <> " I completed #{length(state.execution_results)} step(s) before stopping."

      true ->
        base <> " Please try again, or break the request into smaller steps."
    end
  end

  defp build_execution_summary(state) do
    plan = state.action_plan
    results_count = length(state.execution_results)

    case plan && plan.kind do
      :tool_call -> "Executed #{plan.tool.tool}.#{plan.tool.action}"
      :multi_tool_plan -> "Executed #{results_count}/#{length(plan.steps)} tool calls"
      :output_proposal -> "Output proposed: #{plan.output.type}"
      :workflow_trigger -> "Workflow triggered: #{plan.workflow.workflow_id}"
      :request_approval -> "Approval requested"
      _ -> (plan && plan.why) || "Action completed"
    end
  end

  defp build_outputs(state, _episode_ctx) do
    plan = state.action_plan

    case plan && plan.kind do
      :output_proposal when not is_nil(plan.output) ->
        [plan.output]

      _ ->
        []
    end
  end

  defp build_findings(state) do
    plan = state.action_plan

    case plan && plan.meta["findings"] do
      findings when is_list(findings) ->
        Enum.map(findings, fn
          %{"action" => "raise"} = f ->
            {:raise, Map.drop(f, ["action"])}

          %{"action" => "clear", "key" => key} = f ->
            {:clear, key, f["reason"] || "Cleared via interactive episode"}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp serialize_plan(%ActionPlan{} = plan) do
    %{
      kind: plan.kind,
      risk: plan.risk,
      why: plan.why,
      tool: plan.tool && Map.from_struct(plan.tool),
      steps: Enum.map(plan.steps, &Map.from_struct/1),
      output: plan.output && Map.from_struct(plan.output),
      workflow: plan.workflow && Map.from_struct(plan.workflow)
    }
  end

  # --- Private: Config loading ---

  defp load_strategy_config(actor_id) do
    # 1. Check persistent_term (set by Actor DSL strategy_config option)
    actor_key = safe_to_atom(actor_id)

    case find_strategy_config_from_persistent_term(actor_key) do
      config when is_map(config) and config != %{} ->
        config

      _ ->
        # 2. Fall back to DB (AgentDefinition table — for dynamic actors)
        load_strategy_config_from_db(actor_id)
    end
  end

  defp find_strategy_config_from_persistent_term(actor_key) do
    :persistent_term.get()
    |> Enum.find_value(fn
      {{:cyclium_strategy_config, ^actor_key, _exp_id}, config} when is_map(config) -> config
      _ -> nil
    end)
  end

  defp load_strategy_config_from_db(actor_id) do
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

  defp safe_to_atom(val) when is_atom(val), do: val

  defp safe_to_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    _ -> val
  end

  defp load_conversation(nil), do: nil
  defp load_conversation(conv_id), do: Conversations.get(conv_id)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  rescue
    _ -> map
  end
end

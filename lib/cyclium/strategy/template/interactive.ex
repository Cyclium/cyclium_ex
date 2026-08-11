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

  The `interpret → validate → preview → execute → summarize` phases are shared
  with the autonomous `Cyclium.Strategy.Template.AgenticTask` template via
  `Cyclium.Strategy.Template.Agentic.Loop`. This template supplies the
  conversation-specific ends: seeding intent from a user message, assembling
  conversation history/findings as context, and converging with conversation
  resolution semantics.
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  require Logger

  alias Cyclium.{ConvergeResult, Conversations}
  alias Cyclium.Strategy.Template.Agentic.Loop

  alias Cyclium.Intent.GoalSpec

  # --- Strategy callbacks ---

  @impl true
  def init(episode, %Cyclium.Trigger.Interactive{} = trigger) do
    strategy_config = Loop.load_strategy_config(episode.actor_id, episode.expectation_id)
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

  def next_step(state, episode_ctx), do: Loop.next_step(state, episode_ctx)

  @impl true
  def handle_result(%{phase: :context_assembly} = state, _step, {:ok, context}) do
    {:ok, %{state | phase: :interpret, gathered_context: context}}
  end

  def handle_result(state, step, result), do: Loop.handle_result(state, step, result)

  @impl true
  def converge(state, _episode_ctx) do
    plan = state.action_plan

    {summary, classification} =
      cond do
        state[:budget_exhausted] ->
          {Loop.budget_exhausted_summary(state),
           %{"primary" => "incomplete", "reason" => "budget_exhausted"}}

        state.deny_reason ->
          {"Plan denied: #{state.deny_reason}",
           %{"primary" => "denied", "reason" => state.deny_reason}}

        plan && plan.kind == :explain_only ->
          {plan.explanation || state.explanation || "Explanation provided",
           %{"primary" => "explain_only"}}

        plan ->
          summary = state.explanation || Loop.build_execution_summary(state)
          {summary, %{"primary" => to_string(plan.kind), "risk" => to_string(plan.risk)}}

        true ->
          {state.explanation || "No action taken", %{"primary" => "no_action"}}
      end

    outputs = build_outputs(state)
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
  def handle_budget_exhausted(state, episode_ctx),
    do: Loop.handle_budget_exhausted(state, episode_ctx)

  @impl true
  def resume_from_block(state, episode), do: Loop.resume_from_block(state, episode)

  # --- Private: Context assembly ---

  defp assemble_context(state, episode_ctx) do
    collected = load_collected_fields(state)
    {findings, findings_loaded} = load_relevant_findings(state, episode_ctx, collected)
    prior_summaries = load_prior_episode_summaries(state)

    %{
      message: state.message,
      principal: state.principal,
      history: state.history,
      findings: findings,
      findings_loaded: findings_loaded,
      prior_summaries: prior_summaries,
      goal: state.goal,
      collected_fields: collected,
      actor_id: episode_ctx.actor_id,
      conversation_id: state.conversation_id
    }
  end

  # Returns {findings, loaded?} so the assembled context can distinguish
  # "loaded, empty" from "failed to load" (Gap 3). Scoping is driven by the
  # `context_findings` config and defaults to :none. Collected fields are the
  # subject lookup for `:subject` scoping in a conversation.
  defp load_relevant_findings(state, episode_ctx, subject_lookup) do
    case Loop.load_context_findings(state.strategy_config, episode_ctx, subject_lookup) do
      {:ok, findings} ->
        {findings, true}

      {:error, reason} ->
        Logger.warning("cyclium: context findings failed to load: #{inspect(reason)}",
          cyclium_actor_id: episode_ctx.actor_id,
          cyclium_episode_id: episode_ctx.episode_id
        )

        {[], false}
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
    error ->
      # Narrowed from a silent `[] ` — a failed load is logged, not mistaken for
      # "no prior summaries" (Gap 3). Still degrades to [] so the turn proceeds.
      Logger.warning(
        "cyclium: prior episode summaries failed to load: #{inspect(error)}",
        cyclium_conversation_id: conv_id
      )

      []
  end

  defp load_collected_fields(%{conversation: nil}), do: %{}

  defp load_collected_fields(%{conversation: conv}) do
    Cyclium.Schemas.Conversation.decode_collected_fields(conv)
  end

  # --- Private: Converge helpers ---

  defp build_outputs(state) do
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
    Loop.build_findings_list(plan && plan.meta["findings"])
  end

  # --- Private: Config loading ---

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

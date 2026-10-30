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

  ## Conversation history

  Each turn's prompt carries the conversation's earlier finished turns: the
  user's message, the reply, and the names of the tools the turn called, as
  alternating user and assistant lines. The prompt after a tool runs carries
  the same history. `strategy_config` `history_turns` caps how many of the most
  recent turns are included (default 20; `0` sends none). The assembled
  context still carries `prior_summaries` for strategies that read it.
  """

  @behaviour Cyclium.EpisodeRunner.Strategy

  require Logger

  alias Cyclium.{ConvergeResult, Conversations}
  alias Cyclium.Strategy.Template.Agentic.Loop

  alias Cyclium.Intent.GoalSpec

  # --- Strategy callbacks ---

  @impl true
  def init(episode, %Cyclium.Trigger.Interactive{} = trigger) do
    # A human is present by definition in a conversation, so write and
    # external-effect plans preview for approval unless the expectation opts
    # out with `require_preview_for_side_effects: false`.
    strategy_config =
      Loop.load_strategy_config(episode.actor_id, episode.expectation_id)
      |> Map.put_new("require_preview_for_side_effects", true)

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
  def resume_from_block(state, episode),
    do: Loop.resume_from_block(state, episode, &assemble_context/2)

  # --- Private: Context assembly ---

  defp assemble_context(state, episode_ctx) do
    collected = load_collected_fields(state)
    {findings, findings_loaded} = load_relevant_findings(state, episode_ctx, collected)
    prior_turns = load_prior_turns(state, episode_ctx[:started_before])

    prior_summaries =
      Enum.map(prior_turns, &Map.take(&1, [:summary, :classification, :started_at]))

    # A trigger that carries its own `history` (a host building the trigger_ref
    # itself) is used as given; otherwise the conversation's earlier turns are.
    history =
      case state.history do
        [_ | _] = given -> given
        _ -> Enum.flat_map(prior_turns, &turn_history/1)
      end

    %{
      message: state.message,
      principal: state.principal,
      history: history,
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

  # The conversation's last `history_turns` finished turns, oldest first: each
  # turn's user message (from its trigger_ref), its reply (the episode summary)
  # and the tools it called. The newest are kept, so a long conversation drops
  # its opening turns rather than its latest ones. `before` bounds them to
  # turns that started earlier, for a plan resumed after an approval.
  defp load_prior_turns(%{conversation_id: nil}, _before), do: []

  defp load_prior_turns(%{conversation_id: conv_id} = state, before) do
    import Ecto.Query

    turns =
      from(e in Cyclium.Schemas.Episode,
        where: e.conversation_id == ^conv_id and e.status == :done,
        order_by: [desc: e.started_at, desc: e.id],
        select: %{
          id: e.id,
          trigger_ref: e.trigger_ref,
          summary: e.summary,
          classification: e.classification,
          started_at: e.started_at
        },
        limit: ^history_turns(state.strategy_config)
      )
      |> started_before(before)
      |> Cyclium.repo().all()
      |> Enum.reverse()

    tools = load_turn_tools(Enum.map(turns, & &1.id))

    Enum.map(turns, fn turn ->
      %{
        message: (turn.trigger_ref || %{})["message"],
        summary: turn.summary,
        classification: turn.classification,
        started_at: turn.started_at,
        tools: Map.get(tools, turn.id, [])
      }
    end)
  rescue
    error ->
      # Narrowed from a silent `[] ` — a failed load is logged, not mistaken for
      # "no prior turns" (Gap 3). Still degrades to [] so the turn proceeds.
      Logger.warning(
        "cyclium: prior conversation turns failed to load: #{inspect(error)}",
        cyclium_conversation_id: conv_id
      )

      []
  end

  defp started_before(query, nil), do: query

  defp started_before(query, before) do
    import Ecto.Query
    where(query, [e], e.started_at < ^before)
  end

  @default_history_turns 20

  defp history_turns(config) do
    case config["history_turns"] do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_history_turns
    end
  end

  # Tool names each turn called, in order, so a follow-up can see what the
  # earlier answer was built from. Names only: results stay in the journal.
  defp load_turn_tools([]), do: %{}

  defp load_turn_tools(episode_ids) do
    import Ecto.Query

    from(s in Cyclium.Schemas.EpisodeStep,
      where: s.episode_id in ^episode_ids and s.kind == :tool_call,
      order_by: [asc: s.step_no],
      select: {s.episode_id, s.tool_name, s.error_class}
    )
    |> Cyclium.repo().all()
    |> Enum.group_by(&elem(&1, 0), fn {_, name, error_class} ->
      if error_class, do: "#{name} (failed)", else: name
    end)
  end

  @history_entry_max_chars 4_000

  defp turn_history(turn) do
    user =
      case turn.message do
        msg when is_binary(msg) and msg != "" ->
          [%{role: "user", content: truncate(msg), at: turn.started_at}]

        _ ->
          []
      end

    reply =
      case turn.summary do
        summary when is_binary(summary) and summary != "" ->
          [
            %{
              role: "assistant",
              content: truncate(summary),
              tools: turn.tools,
              at: turn.started_at
            }
          ]

        _ ->
          []
      end

    user ++ reply
  end

  defp truncate(text) when byte_size(text) <= @history_entry_max_chars, do: text

  defp truncate(text) do
    if String.length(text) <= @history_entry_max_chars,
      do: text,
      else: String.slice(text, 0, @history_entry_max_chars) <> "…"
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

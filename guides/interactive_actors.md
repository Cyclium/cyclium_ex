# Building Interactive Actors

This guide covers how to build a conversational, chat-style actor using Cyclium's Interactive strategy template. Interactive actors support multi-turn conversations where users send messages, the LLM interprets intent, tools execute, and results are summarized back to the user.

## Architecture Overview

An interactive actor uses **one episode per conversation turn**. Each user message creates an episode that flows through 7 phases:

```
context_assembly → interpret → validate → [preview] → execute → summarize → converge
```

| Phase | What happens |
|---|---|
| **context_assembly** | Gathers conversation history, findings, collected fields, and goal context |
| **interpret** | Calls the synthesizer (LLM) to produce an `ActionPlan` from the user's message |
| **validate** | Runs the plan through `PlanGate` (structural → signature → constraints → policy) |
| **preview** | *(conditional)* Blocks for user approval if plan has side effects and `require_preview_for_side_effects` is enabled |
| **execute** | Runs the plan — tool calls, output proposals, workflow triggers, or skips for explain_only |
| **summarize** | After tool execution, calls the LLM again to generate a human-readable summary. Can also trigger follow-up tool calls for multi-step reasoning |
| **converge** | Produces findings, outputs, and the episode summary (displayed to the user) |

### Multi-Step Tool Chains

The summarize phase enables multi-step reasoning within a single episode. After a tool executes, the LLM sees the results and can either:
- Return `explain_only` to summarize for the user (episode converges)
- Return another `tool_call` to make a follow-up call (loops back to validate → execute → summarize)

Example: "Do a health check for Dormant LLC"
1. LLM → `list_clients` (to find the UUID)
2. Tool returns client list
3. Summarize → LLM returns `initiate_health_check` with Dormant's UUID
4. Tool fires the health check
5. Summarize → LLM explains the result to the user
6. Converge

## Implementation Checklist

Building an interactive actor requires these pieces:

### In the library (cyclium_ex) — built-in, no changes needed
- [x] `Cyclium.Strategy.Template.Interactive` — 7-phase strategy template
- [x] `Cyclium.Synthesizer.Interactive` — default synthesizer with LLM callback
- [x] `Cyclium.Conversations.Dispatch` — library-level dispatch helper
- [x] `Cyclium.Conversations.LiveHelpers` — reusable LiveView helpers
- [x] `:interactive` trigger deserialization in `EpisodeTask`
- [x] `Conversations.list_for_actor/2` for listing conversations

### In the consuming app
1. **Migration** — V15 creates `cyclium_conversations` table
2. **Actor module** — declares the actor with Interactive strategy
3. **LLM client** — implements `Cyclium.Synthesizer.Interactive.LLM` behaviour (just a `chat/3` callback)
4. **Tool module** — implements `Cyclium.Tool` with your domain actions
5. **Capability registry** — maps capability atoms to tool modules
6. **LiveView UI** — chat interface using library helpers + shared components
7. **Config** — register actor and capability registry

## Step-by-Step Guide

### 1. Migration

Create a migration delegator for V15:

```elixir
# priv/repo/migrations/20260306000015_cyclium_v15.exs
defmodule MyApp.Repo.Migrations.CycliumV15 do
  use Ecto.Migration
  def up, do: Cyclium.Migrations.up(version: 15)
  def down, do: Cyclium.Migrations.down(version: 15)
end
```

### 2. Actor Module

The actor uses `Cyclium.Strategy.Template.Interactive` as the strategy and the tuple synthesizer syntax to wire up the library-level synthesizer with your LLM client.

```elixir
defmodule MyApp.Actors.SupportActor do
  use Cyclium.Actor

  actor do
    identifier(:support_actor)
    domain(:customer_support)
    spec_rev("v0.1.0")
    max_concurrent_episodes(5)
    episode_overflow(:queue)

    synthesizer({Cyclium.Synthesizer.Interactive,
      llm: MyApp.Actors.SupportLLM})

    expectation(:support_conversation,
      strategy: Cyclium.Strategy.Template.Interactive,
      trigger: :interactive,
      log_strategy: :full_debug,
      budget: %{max_turns: 20, max_tokens: 10_000, max_wall_ms: 120_000},
      strategy_config: %{
        role: "You are a support assistant that helps users manage their items.",
        guidelines: [
          "If the user asks about a specific item by name, first use list_items to find the ID",
          "Keep explanations concise and helpful"
        ],
        allowed_tool_signatures: [
          %{
            name: "support",
            side_effect: "read",
            actions: [
              %{name: "list_items", args: %{}, description: "list all items with summary"},
              %{name: "lookup_item", args: %{"item_id" => "UUID"}, description: "get full details for one item"}
            ]
          }
        ],
        require_preview_for_side_effects: false,
        max_plan_steps: 6
      }
    )
  end
end
```

The `strategy_config` declares the full interactive configuration inline — no DB seed needed. The Actor DSL normalizes atom keys to strings and stores it in persistent_term at boot.

**How the system prompt is generated:**

Instead of writing a verbose system prompt manually, provide `role` (personality), `guidelines` (domain rules), and `actions` on each tool signature. `Cyclium.Synthesizer.PromptBuilder` auto-generates the full prompt including JSON schema examples, tool documentation, and response format instructions.

You can still provide a raw `system_prompt` key instead of `role` for full control — the builder passes it through unchanged.

The tuple `{Cyclium.Synthesizer.Interactive, llm: MyApp.Actors.SupportLLM}` tells the Actor DSL to:
1. Register `Cyclium.Synthesizer.Interactive` as the synthesizer module
2. Store the LLM client (`MyApp.Actors.SupportLLM`) in persistent_term so the synthesizer can resolve it at runtime

**Budget guidance:**
- `max_turns` — each phase transition is a turn; a simple explain_only uses ~5 turns, a tool_call uses ~7, multi-step chains use more
- `max_tokens` — cumulative synthesis token cost across all LLM calls in the episode
- `max_wall_ms` — wall clock timeout; LLM calls can be slow, so allow at least 60s

**strategy_config keys:**

| Key | Type | Purpose |
|---|---|---|
| `role` | string | Actor personality/description — PromptBuilder generates the full system prompt from this |
| `guidelines` | list of strings | Domain-specific rules — appended to the generated prompt |
| `system_prompt` | string | *Alternative:* raw system prompt (bypasses PromptBuilder, use for full control) |
| `allowed_tool_signatures` | list of maps | Tool signatures with `name`, `side_effect`, optional `actions` (list of `%{name, args, description}`) |
| `require_preview_for_side_effects` | boolean | If true, plans with write/external_effect tools block at preview for approval |
| `max_plan_steps` | integer | Max steps in a multi_tool_plan |

**Tool signature `actions` format:**

Each action in a tool signature maps to a `call/3` clause in your tool module:

```elixir
%{
  name: "lookup_item",          # matches call(:lookup_item, args, ctx)
  args: %{"item_id" => "UUID"}, # arg schema shown to the LLM
  description: "get full details for one item",
  risk: "medium"                # optional — shown to LLM, default is "low"
}
```

**DB fallback for dynamic actors:** If `strategy_config` is not set in the DSL, the Interactive template falls back to loading from the `cyclium_agent_definitions` table. This supports dynamic actors configured at runtime without compiled modules.

### 3. LLM Client

Instead of writing a full synthesizer (~200 lines of prompt building, JSON parsing, error handling), just implement the `Cyclium.Synthesizer.Interactive.LLM` behaviour with a single `chat/3` callback:

```elixir
defmodule MyApp.Actors.SupportLLM do
  @behaviour Cyclium.Synthesizer.Interactive.LLM

  @impl true
  def chat(system_prompt, user_message, opts \\ []) do
    MyApp.Anthropic.chat(system_prompt, user_message, opts)
  end
end
```

The library-level `Cyclium.Synthesizer.Interactive` handles everything else:
- Building structured user messages from context, tool menu, history, and findings
- Routing between `:interpret_intent` and `:summarize_results` tasks
- Parsing JSON responses (including extracting from markdown code fences)
- Falling back to `explain_only` when JSON parsing fails
- Graceful `:no_api_key` handling with placeholder responses
- Token estimation for budget tracking

**Custom synthesizer (advanced):** If you need full control over prompt construction, you can still implement `Cyclium.Synthesizer` directly. Set `synthesizer(MyApp.CustomSynthesizer)` in the actor (without the tuple). See the "Custom Synthesizer" section below.

### 4. Tool Module

Implement `Cyclium.Tool` with action-based dispatch. The tool name (capability atom) is what the LLM references in ActionPlans.

```elixir
defmodule MyApp.Tools.SupportTool do
  use Cyclium.Tool

  @impl true
  def call(:list_items, _args, _ctx) do
    items = MyApp.Items.list_all()
    {:ok, %{items: Enum.map(items, &format/1), count: length(items)}}
  end

  def call(:lookup_item, args, _ctx) do
    item = MyApp.Items.get!(args["item_id"] || args[:item_id])
    {:ok, format(item)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def call(_action, _args, _ctx), do: {:error, :unknown_action}

  @impl true
  def side_effect?, do: false  # true if any action has side effects
end
```

**Best practices for tools:**
- Accept both string and atom keys in args (`args["id"] || args[:id]`) — the LLM returns string keys, but internal callers may use atoms
- Return structured maps, not raw Ecto structs — the results get JSON-serialized for checkpoints and logging
- Set `side_effect?` to `true` if any action writes data. This affects signature matching and preview gating.
- Always include a catch-all `call(_action, _args, _ctx)` clause

### 5. Capability Registry

Maps capability atoms to tool modules. Referenced by `ToolExec.call/4` during execution.

```elixir
defmodule MyApp.CapabilityRegistry do
  def tool_for(:support), do: MyApp.Tools.SupportTool
  def tool_for(_), do: nil
end
```

Register in config:

```elixir
config :cyclium, :capability_registry, MyApp.CapabilityRegistry
```

The capability name (`:support`) must match the `"tool"` field in the LLM's ActionPlan JSON and the `"name"` in tool signatures.

### 6. Conversation Dispatch

The library provides `Cyclium.Conversations.Dispatch` which automatically resolves the actor's interactive expectation, budget, and log strategy from persistent_term. No hardcoded expectation IDs needed.

```elixir
# Thin wrapper — optional, you can call the library module directly
defmodule MyApp.ConversationDispatch do
  defdelegate send_message(conversation_id, message, opts \\ []),
    to: Cyclium.Conversations.Dispatch
end
```

Or call the library directly from your LiveView:

```elixir
Cyclium.Conversations.Dispatch.send_message(conversation_id, message, principal: user)
```

**How dispatch resolution works:**
1. Loads conversation to get `actor_id`
2. Scans persistent_term for an expectation using `Cyclium.Strategy.Template.Interactive`
3. Resolves budget and log_strategy from the same persistent_term entries
4. Creates episode with `trigger_type: :interactive` and enqueues it
5. Broadcasts `"expectation.triggered"` bus event

**Key details:**
- The `dedupe_key` includes a millisecond timestamp for uniqueness
- History is loaded from DB at runtime by the Interactive template's `load_prior_episode_summaries/1` — not embedded in trigger_ref (avoids O(N) data duplication)
- `trigger_type: :interactive` is required — this is how `EpisodeTask` knows to deserialize into `Cyclium.Trigger.Interactive`

### 7. Conversation UI

The conversation UI has four parts: shared components, chat page (Show), list page (Index), and JS hooks + CSS. See the dedicated [Conversation UI Guide](conversation_ui.md) for full details.

The library provides `Cyclium.Conversations.LiveHelpers` to reduce boilerplate — see that guide for usage.

### 8. Config

Register the actor and capability registry in your app config:

```elixir
# config/config.exs
config :cyclium, :capability_registry, MyApp.CapabilityRegistry

config :my_app, :cyclium_actors, [
  {MyApp.Actors.SupportActor, []}
]
```

## ActionPlan JSON Schema

The LLM must return one of these JSON shapes. The Interactive strategy parses them into `%ActionPlan{}` structs.

### explain_only — answer questions, summarize data

```json
{"kind": "explain_only", "risk": "low", "why": "reason", "explanation": "response text"}
```

### tool_call — invoke a single tool

```json
{
  "kind": "tool_call",
  "risk": "low",
  "why": "looking up client data",
  "tool": {"tool": "support", "action": "lookup_item", "args": {"item_id": "uuid"}}
}
```

### workflow_trigger — start a workflow

```json
{
  "kind": "workflow_trigger",
  "risk": "medium",
  "why": "user requested full review",
  "workflow": {"workflow_id": "health_review", "input": {"client_id": "uuid"}}
}
```

### Conversation resolution

Any response can signal conversation end by including `meta`:

```json
{
  "kind": "explain_only",
  "risk": "low",
  "why": "user said goodbye",
  "explanation": "Goodbye!",
  "meta": {"resolve_conversation": true, "outcome": "completed"}
}
```

## Custom Synthesizer (Advanced)

If the library-level `Cyclium.Synthesizer.Interactive` doesn't fit your needs (e.g., you need custom prompt structure, multi-message conversation context, or a different JSON schema), implement `Cyclium.Synthesizer` directly:

```elixir
defmodule MyApp.Actors.CustomSynthesizer do
  @behaviour Cyclium.Synthesizer

  @impl true
  def synthesize(prompt_ctx, _episode_ctx) do
    system_prompt = prompt_ctx[:system_prompt] || "..."

    case prompt_ctx[:task] do
      :summarize_results -> synthesize_summary(system_prompt, prompt_ctx)
      _ -> synthesize_interpret(system_prompt, prompt_ctx)
    end
  end

  @impl true
  def estimate_tokens(prompt_ctx) do
    msg = prompt_ctx[:message] || ""
    context = prompt_ctx[:context] || %{}
    history_size = length(context[:prior_summaries] || []) * 100
    div(String.length(msg) + history_size + 500, 4)
  end

  # ... your custom prompt building and parsing ...
end
```

Key requirements:
- Must handle both `:interpret_intent` and `:summarize_results` tasks
- Must return `{:ok, map}` where map has ActionPlan fields (`kind`, `risk`, `why`, etc.)
- The summarize prompt must explicitly allow both `explain_only` and `tool_call` responses to enable multi-step chains
- Set `synthesizer(MyApp.Actors.CustomSynthesizer)` in the actor (no tuple)

## Gotchas and Lessons Learned

### Checkpoint vs Observe for phase transitions

The EpisodeRunner's `{:checkpoint, phase_name}` action saves state but **does not call `handle_result`**. If a strategy needs to transition phases based on a synchronous check (like validation), use `{:observe, data}` instead — it journals the step AND calls `handle_result`, allowing the strategy to update its phase.

### Jason.Encoder for checkpoint serialization

The EpisodeRunner serializes strategy state to JSON for checkpoints. Any struct stored in state must derive `Jason.Encoder`:

```elixir
@derive Jason.Encoder                           # for simple structs
@derive {Jason.Encoder, only: [:id, :name, ...]} # for Ecto schemas (exclude __meta__)
```

Structs that need this: `Conversation`, `ActionPlan`, `ToolCallStep`, `WorkflowTrigger`, `GoalSpec`.

### Loop detection

The EpisodeRunner tracks step fingerprints and fails with `loop_detected` if it sees repeating cycles. This catches bugs where a phase doesn't transition. If you see `loop_detected`, check that your `handle_result` clause actually matches the step shape being passed — the catch-all `handle_result(state, _step, _result) -> {:ok, state}` silently swallows mismatches and keeps the phase unchanged.

### Tool arg keys are strings

The LLM returns JSON with string keys (`"client_id"`). Always accept both in tool `call/3`:

```elixir
client_id = args["client_id"] || args[:client_id]
```

### Summarize enables multi-step chains

Without the summarize phase, tool_call episodes converge with a technical summary like "Executed support.list_items". The summarize phase calls the LLM again with the tool results so it can produce a human-readable response — or make another tool call if the user's request requires multiple steps.

### Budget sizing

A simple explain_only turn uses ~5 runner turns. A tool_call with summarize uses ~7. Multi-step chains (tool → summarize → tool → summarize) use ~12+. Set `max_turns` high enough for your expected workflows. When in doubt, start with 20 and tune based on log data.

### Side effect classification

Set `"side_effect"` in tool signatures accurately:
- `"read"` — queries, lookups (risk: low)
- `"write"` — mutations, state changes (risk: medium+)
- `"external_effect"` — emails, webhooks, external API calls (risk: high)

When `require_preview_for_side_effects` is true in strategy_config, plans with write/external_effect tools will block at the preview phase for user approval before executing.

### Filter bus events by actor_id in the UI

`Cyclium.Bus.subscribe()` delivers ALL bus events to the LiveView — not just events from your interactive actor. If a tool triggers a workflow (e.g., `initiate_health_check` starts a `ClientHealthWorkflow`), the workflow's step episodes will broadcast `episode.completed` and `episode.failed` events. Without actor_id filtering, the chat UI may display spurious "something went wrong" messages from unrelated actors.

Always pattern match on `actor_id` in bus event handlers:

```elixir
# Good — only handles events from this actor
def handle_info({:bus, "episode.completed", %{episode_id: id, actor_id: @__actor_id}}, socket)

# Bad — handles events from ALL actors
def handle_info({:bus, "episode.completed", %{episode_id: id}}, socket)
```

### Conversation history is loaded from DB, not trigger_ref

Earlier designs embedded conversation history in `trigger_ref.history` on every episode. This caused O(N) data duplication — each episode stored all prior summaries. The current design only stores `message`, `conversation_id`, and `principal` in trigger_ref. History is loaded fresh from DB by the Interactive template's `load_prior_episode_summaries/1` during context_assembly.

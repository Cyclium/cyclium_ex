# Actors and Strategies

The core building blocks of Cyclium: actors own expectations, expectations fire
episodes, and strategies are the brains of an episode. This guide covers the
actor DSL, the strategy lifecycle, multi-turn strategies, episodes, budgets,
deduplication, tools, and synthesizers.

> The examples throughout use a generic **resource monitoring** domain: a
> `ResourceMonitor` actor that evaluates a resource (its usage against a limit)
> and classifies status. Swap `resource` for whatever domain you're modeling.

## Strategy-driven vs. LLM-routed

Most agent frameworks put the LLM in the driver's seat — it decides which tool
to call, when to stop, and how to recover from errors. Cyclium inverts this. The
**developer is the router**: your `next_step/2` function is a deterministic state
machine that decides what happens next. The LLM is a powerful tool you call at
specific points via `:synthesize`, but it never controls the flow.

This means you can mix deterministic and AI-powered steps in a single episode —
gather data with a tool call, classify it with an LLM, then act on the result
with another tool call — all under explicit developer control with budget
enforcement at every turn:

```elixir
def next_step(%{phase: :gather} = state, _ctx) do
  {:tool_call, :data_source, :search_records, %{status: "active"}}
end
def next_step(%{phase: :classify, records: records} = state, _ctx) do
  {:synthesize, %{task: :classify_records, data: records}}
end
def next_step(%{phase: :act, classification: "needs_attention"} = state, _ctx) do
  {:tool_call, :notifier, :send_notification, build_notification(state)}
end
```

You get repeatability, testability, and full visibility into exactly which steps
ran and why — without sacrificing the ability to use AI where it adds value.

## Actors

An **actor** is a GenServer that owns one or more **expectations**. Each actor
watches a domain (e.g., `:resource`, `:billing`) and fires **episodes** when
triggers match.

An **expectation** is a named, triggerable process: it binds a trigger to a
strategy and a budget. When the trigger fires, an episode runs that strategy.

```elixir
defmodule MyApp.Actors.ResourceMonitor do
  use Cyclium.Actor

  actor do
    domain(:resource)
    spec_rev("v0.1.0")
    max_concurrent_episodes(5)
    episode_overflow(:queue)

    expectation(:check_resource_limits,
      strategy: MyApp.Strategies.ResourceLimits,
      trigger: {:event, "resource.updated"},
      subject_key: :resource_id,
      debounce_ms: :timer.seconds(3),
      budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}
    )

    expectation(:periodic_review,
      strategy: MyApp.Strategies.ResourceReview,
      trigger: {:schedule, :timer.hours(24)},
      recovery_policy: :restart,
      budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}
    )
  end
end
```

**Trigger types:**

- `{:event, "event.name"}` — fires when a matching Bus event arrives
- `{:schedule, interval_ms}` — fires on a recurring timer (every N ms, anchored to
  the last fire; **not** a wall-clock time)
- `{:cron, "0 5 * * *"}` — fires at a wall-clock time (UTC). See [Cron triggers](#cron-triggers) below
- `:manual` — fires on explicit request
- `:workflow` — fires as part of a multi-actor workflow
- **List** — combine multiple triggers: `[{:event, "resource.updated"}, :workflow]`

**List triggers** allow an expectation to fire from multiple sources. Event
subscriptions and schedule timers are extracted from the list automatically.
This is the recommended pattern when an expectation participates in a workflow
but should also be independently triggerable:

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: [{:event, "resource.updated"}, :workflow],
  subject_key: :resource_id,
  debounce_ms: :timer.seconds(3),
  budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}
)
```

The actor subscribes to `"resource.updated"` for standalone use (with debounce),
while the `:workflow` marker documents that workflows can also invoke this
expectation. Workflow-triggered episodes bypass the actor GenServer entirely —
the workflow engine creates episodes directly — so actor-level debounce/cooldown
only applies to event triggers.

#### Cron triggers

Use `{:cron, spec}` for wall-clock schedules. `{:schedule, ms}` fires every N ms
*anchored to the last fire* (so it drifts to whenever it started); `{:cron, ...}`
fires at a fixed time of day:

```elixir
expectation(:daily_rollup,
  strategy: MyApp.Strategies.DailyRollup,
  trigger: {:cron, "0 5 * * *"}            # 05:00 UTC every day
)
```

Standard 5-field crontab — `minute hour day-of-month month day-of-week` — with
`*`, lists (`,`), ranges (`a-b`), and steps (`*/n`, `a-b/n`). Day-of-week is
`0..6` (Sunday = 0; `7` also accepted). When **both** day-of-month and day-of-week
are restricted, a tick matches if **either** does (standard Vixie-cron rule).
Macros: `@hourly`, `@daily`/`@midnight`, `@weekly`, `@monthly`, `@yearly`/`@annually`.

Key properties:

- **UTC only.** No time-zone or DST handling — `"0 5 * * *"` is 05:00 UTC.
- **At-most-once per tick, cluster-wide.** Every node computes the same occurrence
  and keys the episode dedupe on the exact tick, so concurrent fires collapse to
  one episode per occurrence (per env — see [Distributed Ops](distributed_ops.md)).
  No external scheduler or leader election needed.
- **No catch-up.** Only the next future tick is scheduled; if the cluster is down
  across a tick, that occurrence is skipped (not replayed).
- **Fail-fast.** A malformed spec raises when the actor boots, not silently never fires.
- Cron can appear in a trigger list too: `[{:cron, "0 5 * * *"}, {:event, "rollup.requested"}]`.
- `window:` is ignored for cron (the tick *is* the dedupe bucket).

**Backpressure options** (`episode_overflow`):

- `:queue` — buffer excess episodes (default)
- `:drop` — discard when at capacity
- `:shed_oldest` — cancel the oldest queued episode to make room

**Expectation options:**

| Option | Default | Description |
|---|---|---|
| `strategy` | required | Strategy module for this expectation. Declared inline — Cyclium registers it when the actor boots |
| `trigger` | required | What fires the episode. Single trigger or list (e.g. `[{:event, "..."}, :workflow]`) |
| `synthesizer` | `nil` | Synthesizer module override for this expectation. Overrides the actor-level `synthesizer(...)` declaration |
| `checkpoint_schema` | `nil` | `Cyclium.CheckpointSchema` module for versioned checkpoint state migration. App-config `:checkpoint_schemas` takes precedence when both are set. See the Advanced guide |
| `filter` | `%{}` | Payload predicates — only fire when all match |
| `debounce_ms` | `nil` | Coalesce rapid events into one firing |
| `cooldown_ms` | `nil` | Minimum gap between firings |
| `subject_key` | `nil` | Payload key to scope debounce/cooldown per subject (e.g., `:resource_id`) |
| `budget` | `%{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}` | Resource limits |
| `log_strategy` | `:timeline` | Controls materialized log verbosity AND step journal detail (see the Observability guide) |
| `outputs` | `[]` | Declared output types (informational) |
| `resources` | `[]` | Declared capability dependencies (informational) |
| `audit_level` | `:standard` | Audit verbosity |
| `retention_days` | `90` | How long to keep episode data. Set higher for audit-sensitive workflows (e.g., 365). Retention is declarative — enforcement requires a scheduled cleanup job (not yet built) |
| `sample_rate` | `nil` | Float 0.0–1.0. When set, episodes fire probabilistically. `nil` or `1.0` = always fire. Force-fire bypasses sampling |
| `circuit_breaker` | `nil` | Circuit breaker config. See the Advanced guide |
| `adaptive_budget` | `false` | When `true`, records episode resource usage for advisory budget recommendations |
| `service_levels` | `nil` | Performance objectives. See the Observability guide |
| `finding_enrichment` | `nil` | Post-raise enrichment callback. See the Findings guide |
| `escalation_rules` | `nil` | Time-based severity escalation. See the Findings guide |
| `finding_ttl_seconds` | `nil` | Default TTL for findings raised by this expectation |
| `loop_detection` | `true` | Set `false` to disable stuck-loop detection (for strategies that legitimately poll a token-free action). See [Loop detection](#loop-detection) |

**Actor ID convention:** Actor IDs are **atoms in-process** and **strings in the
database**. Use `identifier/1` in the DSL to set a stable actor ID that survives
module renames:

```elixir
actor do
  identifier(:resource_monitor)   # explicit, rename-proof
  domain(:resource)
  # ...
end
```

If omitted, the ID is derived from the module name
(`MyApp.Actors.ResourceMonitor` → `:resource_monitor`). The boundary is at
episode creation — `Cyclium.Actor.Server` calls `to_string(state.actor_id)` when
building the episode params. Everything upstream is atoms, everything downstream
(DB, strategies, findings) is strings. **Actors with persisted episodes should
always declare an explicit identifier.**

## Strategies

A **strategy** implements the investigation logic for an expectation. It's the
brain of an episode — a stateless module that receives state and returns actions.

```elixir
defmodule MyApp.Strategies.ResourceLimits do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, trigger) do
    resource_id = trigger.payload["resource_id"]
    {:ok, %{resource_id: resource_id}}
  end

  @impl true
  def next_step(state, _episode_ctx) do
    :converge  # go straight to classification
  end

  @impl true
  def handle_result(state, _step, _result) do
    {:ok, state}
  end

  @impl true
  def converge(state, _episode_ctx) do
    resource = MyApp.Resources.get!(state.resource_id)
    {class, severity, summary} = classify(resource)

    {:ok, %Cyclium.ConvergeResult{
      classification: %{"primary" => class, "severity" => to_string(severity)},
      confidence: 1.0,
      summary: summary,
      findings: [
        {:raise, %{
          actor_id: "resource_monitor",
          finding_key: "resource:limits:#{resource.id}",
          class: class,
          severity: severity,
          confidence: 1.0,
          subject: %{kind: "resource", id: resource.id},
          subject_kind: "resource",
          subject_id: resource.id,
          summary: summary,
          evidence_refs: %{"percent_used" => resource.used / max(resource.limit, 1)}
        }}
      ],
      outputs: []
    }}
  end

  defp classify(%{status: :decommissioned}), do: {"decommissioned", :low, "Resource decommissioned"}
  defp classify(%{used: used, limit: limit}) do
    pct = used / max(limit, 1)
    cond do
      pct > 1.0  -> {"over_limit", :high, "Over allocated limit"}
      pct > 0.85 -> {"limit_risk", :medium, "Approaching limit"}
      true       -> {"healthy", :low, "Within limits"}
    end
  end
end
```

**Strategy callbacks:**

| Callback | Purpose |
|---|---|
| `init(episode, trigger)` | Initialize state from trigger data. Return `{:ok, state}` |
| `next_step(state, episode_ctx)` | Decide the next action (see table below) |
| `handle_result(state, step, result)` | Process a step's outcome. Return `{:ok, state}`, `{:retry, state}`, or `{:abort, reason}` |
| `converge(state, episode_ctx)` | Produce findings, outputs, and classification. Return `{:ok, ConvergeResult}` |
| `workflow_result(state, converge_result)` | *(optional)* Extract data to pass to downstream workflow steps |

**`next_step` return values:**

| Return | Effect |
|---|---|
| `:done` | Episode complete (skip converge phase) |
| `:converge` | Run the converge pipeline |
| `{:tool_call, capability, action, args}` | Call a registered tool capability, pass result to `handle_result` |
| `{:observe, data}` | Journal `data` as an observation step, then pass `{:ok, data}` to `handle_result`. A synchronous in-process action — no external system is called. Use it to feed data you've already gathered into the strategy's result-handling flow |
| `{:synthesize, prompt_ctx}` | Request LLM synthesis via app-provided `Cyclium.Synthesizer`. The synthesizer calls the LLM, and the response flows to `handle_result` |
| `{:checkpoint, phase_name}` | Save strategy state for crash recovery |
| `{:output, type, payload}` | Propose an output inline (outside converge) |
| `{:approval, request}` | Block episode until human approval |
| `{:wait, external_ref}` | Block episode until external event resolves |

**`handle_result` step kinds:**

The `step` argument passed to `handle_result/3` is an `%EpisodeStep{}` struct.
Pattern-match on `kind` to distinguish which action produced the result:

| `step.kind` | Produced by | `result` on success | `result` on failure |
|---|---|---|---|
| `:tool_call` | `{:tool_call, capability, action, args}` | `{:ok, tool_return_value}` | `{:error, {error_class, detail}}` |
| `:synthesis` | `{:synthesize, prompt_ctx}` | `{:ok, llm_response}` | `{:error, {error_class, detail}}` |
| `:observation` | `{:observe, data}` | `{:ok, data}` | *(never fails — data is passed through as-is)* |

The step struct also carries `tool_name` (for `:tool_call` steps) which is
useful for per-tool retry tracking:

```elixir
def handle_result(state, %{kind: :synthesis}, {:ok, result}), do: ...
def handle_result(state, %{kind: :tool_call, tool_name: "data_source"}, {:ok, data}), do: ...
def handle_result(state, %{kind: :observation}, {:ok, data}), do: ...
```

## Multi-turn strategies

Strategies can run multiple turns before converging. `next_step` decides actions,
`handle_result` absorbs outcomes — expensive work like LLM calls should be
delegated to actions (`:synthesize`, `:tool_call`), not done inside
`handle_result`.

**Use a `:phase` field in state to drive progression.** This is the recommended
pattern — it makes flow explicit, prevents ambiguous matching in `handle_result`,
and avoids accidental loops:

```elixir
defmodule MyApp.Strategies.ResourceAdvisor do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @system_prompt "You are an operations analyst. Assess the resource's health."

  @impl true
  def init(_episode, trigger) do
    # Load data in init — next_step should be pure routing, not queries
    resource_id = trigger.payload["resource_id"]
    resource = MyApp.Resources.get!(resource_id)
    resource_data = Map.take(resource, [:name, :status, :used, :limit])
    {:ok, %{phase: :synthesize, resource_id: resource_id, resource_data: resource_data, ai_summary: nil}}
  end

  # --- next_step: pure routing based on phase ---

  @impl true
  def next_step(%{phase: :synthesize} = state, _episode_ctx) do
    {:synthesize, %{
      system_prompt: @system_prompt,
      user_message: "Resource: #{state.resource_data.name}, used: #{state.resource_data.used}/#{state.resource_data.limit}"
    }}
  end

  def next_step(%{phase: :done}, _episode_ctx), do: :converge

  # --- handle_result: ALWAYS guard on phase ---

  @impl true
  def handle_result(%{phase: :synthesize} = state, _step, {:ok, result}) do
    summary = if is_map(result), do: result[:text] || result["text"] || inspect(result), else: inspect(result)
    {:ok, %{state | phase: :done, ai_summary: summary}}
  end

  def handle_result(%{phase: :synthesize} = state, %{kind: :synthesis}, {:error, {_class, _detail}}) do
    # Transient failure — retry the same step (next_step will re-emit :synthesize)
    {:retry, state}
  end

  def handle_result(_state, _step, {:error, reason}) do
    {:abort, reason}
  end

  @impl true
  def converge(state, _episode_ctx) do
    {:ok, %Cyclium.ConvergeResult{
      classification: %{"primary" => "ai_summary", "severity" => "low"},
      confidence: 0.9,
      summary: state.ai_summary,
      findings: [
        {:raise, %{
          actor_id: "resource_advisor",
          finding_key: "resource:advisory:#{state.resource_id}",
          class: "ai_summary",
          severity: :low,
          confidence: 0.9,
          subject_kind: "resource",
          subject_id: state.resource_id,
          summary: state.ai_summary
        }}
      ],
      outputs: []
    }}
  end
end
```

**Key points:**

- `next_step` is pure decision-making — it returns what action to take, never
  does expensive work itself
- `handle_result` absorbs outcomes — it pattern-matches on step kind and result,
  then updates state
- `{:retry, state}` re-enters the loop with the same state, letting `next_step`
  retry the action
- `{:abort, reason}` immediately fails the episode with the given reason
- The `:synthesize` action delegates LLM calls to the app-provided
  `Cyclium.Synthesizer`, keeping the strategy free of HTTP concerns

### Multi-step patterns and pitfalls

**Always guard `handle_result` on `:phase`.** The most common multi-step bug is
an unguarded `handle_result` clause that matches too broadly, causing the
strategy to cycle between phases instead of progressing:

```elixir
# BAD — matches ANY success result during any phase
def handle_result(state, _step, {:ok, result}) do
  {:ok, %{state | phase: :done, ai_summary: inspect(result)}}
end

# GOOD — each clause is scoped to its phase
def handle_result(%{phase: :synthesize} = state, _step, {:ok, result}) do
  {:ok, %{state | phase: :done, ai_summary: extract_text(result)}}
end

def handle_result(%{phase: :tool_result} = state, _step, {:ok, data}) do
  {:ok, %{state | phase: :synthesize, gathered: data}}
end
```

Without phase guards, `handle_result` matches the wrong clause → phase doesn't
advance → `next_step` re-emits the same action → loop. The budget will eventually
kill it, but you'll burn turns for no reason.

**Handle the no-synthesizer passthrough.** When no `Cyclium.Synthesizer` is
configured (or the registry returns `nil` for your actor), the runner passes
`prompt_ctx` through as-is to `handle_result` with `{:ok, prompt_ctx}`. Your
`:synthesize` phase handler must handle both the LLM response shape AND the raw
passthrough:

```elixir
def handle_result(%{phase: :synthesize} = state, _step, {:ok, result}) do
  summary =
    cond do
      is_binary(result) -> result
      is_map(result) && Map.has_key?(result, :text) -> result.text
      is_map(result) && Map.has_key?(result, "text") -> result["text"]
      true -> inspect(result)  # passthrough — no synthesizer configured
    end

  {:ok, %{state | phase: :done, ai_summary: summary}}
end
```

**Handle both trigger types if your actor can be triggered by workflows.**
Workflow-created episodes use `%Cyclium.Trigger.Workflow{input: ...}`, not
`%Cyclium.Trigger.Event{payload: ...}`:

```elixir
def init(_episode, trigger) do
  resource_id =
    case trigger do
      %Cyclium.Trigger.Event{payload: %{resource_id: id}} -> id
      %Cyclium.Trigger.Event{payload: payload} -> payload["resource_id"]
      %Cyclium.Trigger.Workflow{input: %{resource_id: id}} -> id
      %Cyclium.Trigger.Workflow{input: input} when is_map(input) -> input["resource_id"]
      _ -> nil
    end

  {:ok, %{phase: :gather, resource_id: resource_id}}
end
```

### Loop detection

The episode runner detects repeating step cycles. It fingerprints each
`next_step` return value and watches for repeated patterns — a 1-step cycle
(A, A, A), a 2-step cycle (A, B, A, B), or longer.

A repeating cycle is only treated as a stuck loop when the episode made **no
budget progress** (no tokens consumed) across the window. A strategy that
legitimately repeats an action while consuming tokens — an LLM retry/refine loop,
for example — is making progress and is bounded by the token budget, so it is
*not* flagged. When a true (token-free) loop is detected, the episode fails with
`error_class: "loop_detected"`.

Consecutive steps of the **same kind but different data** are also fine — the
fingerprint includes the full action payload via `:erlang.phash2/1`, so a
dispatch strategy emitting `:observe` steps with different entity data won't
trip it. Only identical actions repeated in a cycle will.

This is a safety net, not a substitute for correct phase guards — if it fires,
usually a `handle_result` phase guard is missing. For a strategy that
legitimately polls a token-free action (e.g. waiting on an external condition),
disable it per expectation:

```elixir
expectation(:poll_until_ready,
  strategy: MyApp.Strategies.Poller,
  trigger: {:event, "resource.updated"},
  loop_detection: false
)
```

## Episodes

An **episode** is one execution of a strategy. It tracks:

- Budget usage (turns, tokens, wall time)
- Step journal (every action recorded as an `EpisodeStep`)
- Classification and summary (set during converge)
- Status lifecycle: `:running` → `:done` | `:failed` | `:blocked` | `:canceled` | `:partially_failed`

Episodes run as Tasks under a DynamicSupervisor — no Oban required. The
`cyclium_episodes` table serves as a durable work queue.

**Querying episodes:**

```elixir
Cyclium.Episodes.get!(episode_id)
Cyclium.Episodes.list_by_status([:running, :done, :failed])
Cyclium.Episodes.list_steps(episode_id)   # step journal
Cyclium.Episodes.get_log(episode_id)      # materialized log
Cyclium.Episodes.cancel(episode_id)       # cancellation sequence

# List episodes by actor(s)
Cyclium.Episodes.list_by_actors(["resource_monitor"], limit: 20, order: :desc)

# Filter by subject — DB-level JSON filtering across trigger types
# Checks trigger_ref.payload.<key> (event-triggered) and
# trigger_ref.input.<key> (workflow-triggered) in a single query.
Cyclium.Episodes.list_by_actors_and_subject(
  ["resource_monitor", "resource_advisor"],
  :resource_id,
  resource.id,
  limit: 20, order: :desc
)
```

`list_by_actors_and_subject/4` detects the repo adapter at runtime and uses the
appropriate JSON text extraction — Postgres `#>>` or SQL Server `JSON_VALUE`.
This is the recommended way to fetch episodes for a specific entity — it avoids
pulling all episodes and filtering in memory.

## Budgets

Every expectation declares a budget. The runner enforces all three dimensions:

```elixir
budget: %{
  max_turns: 12,        # loop iterations (incremented every next_step call)
  max_tokens: 25_000,   # LLM token cost (incremented by tool_call results)
  max_wall_ms: 120_000  # wall-clock deadline (enforced via Process.send_after)
}
```

When any limit is hit, the episode fails with `error_class: "budget_exceeded"`.
Wall time is enforced asynchronously — a `:budget_wall_exceeded` message
interrupts the loop even if the strategy is blocked on a tool call.

See the Observability guide for **adaptive budgets**, which recommend budget
values from historical episode usage.

## Deduplication: actor-level vs. strategy-level

Cyclium provides three layers of temporal dedup:

**Actor-level global (`cooldown_ms`)** — enforced by the actor GenServer before
an episode starts. Simple and zero-cost, but applies globally to the
expectation — *all* subjects are blocked during the window.

```elixir
expectation(:resource_advisory,
  strategy: MyApp.Strategies.ResourceAdvisor,
  trigger: {:event, "resource.advisory_requested"},
  cooldown_ms: :timer.minutes(5)  # no advisory episodes for ANY resource for 5 min
)
```

**Actor-level per-subject (`subject_key` + `debounce_ms`/`cooldown_ms`)** — when
`subject_key` is set, debounce and cooldown are scoped per subject value. Each
unique subject gets its own independent trailing-edge timer and cooldown window.
Resource A and resource B are debounced independently.

```elixir
expectation(:resource_advisory,
  strategy: MyApp.Strategies.ResourceAdvisor,
  trigger: {:event, "resource.advisory_requested"},
  subject_key: :resource_id,
  debounce_ms: :timer.seconds(10),   # trailing-edge, per-resource
  cooldown_ms: :timer.minutes(5)     # minimum gap, per-resource
)
```

When `subject_key` is set but the payload doesn't contain that key, the subject
value is `nil` and the key becomes `{expectation_id, nil}` — still isolated from
real subjects, never crashing.

**Strategy-level (`Findings.recent?/2`)** — checked in `init/2` using the
existing finding for a specific subject. This is DB-backed, so it survives actor
restarts unlike the in-memory actor-level dedup.

```elixir
@advisory_cooldown_ms :timer.minutes(5)

def init(_episode, trigger) do
  resource_id = trigger.payload["resource_id"]
  skip = Cyclium.Findings.recent?("resource:advisory:#{resource_id}", @advisory_cooldown_ms)
  {:ok, %{resource_id: resource_id, skip: skip}}
end

def next_step(%{skip: true}, _ctx), do: :done
```

**When to use which:**

| Scenario | Use |
|---|---|
| Rate-limit a high-frequency trigger globally | `cooldown_ms` on the expectation |
| Coalesce rapid events per subject before firing | `subject_key` + `debounce_ms` |
| Minimum gap between runs per subject | `subject_key` + `cooldown_ms` |
| Dedup that survives actor restarts (DB-backed) | `Findings.recent?/2` in `init/2` |
| Belt-and-suspenders | `subject_key` + `debounce_ms` as fast path, `Findings.recent?/2` for persistence across restarts |

## Tools

External capabilities are registered as tools implementing `Cyclium.Tool`. Use
`use Cyclium.Tool` for sensible defaults — the only required callback is
`call/3`:

```elixir
defmodule MyApp.Tools.DataSource do
  use Cyclium.Tool

  @impl true
  def call(:read_record, args, _ctx) do
    case MyApp.Store.get_record(args["record_id"]) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Override optional callbacks as needed:

```elixir
defmodule MyApp.Tools.Notifier do
  use Cyclium.Tool

  @impl true
  def call(:send_notification, args, _ctx), do: # ...

  # Strip credentials before journaling
  @impl true
  def redact(args), do: Map.drop(args, ["api_key"])

  # Strip large payloads from results before journaling
  @impl true
  def redact_result(result) when is_list(result) do
    %{count: length(result), ids: Enum.map(result, & &1.id)}
  end
  def redact_result(result), do: result

  # Mark as having side effects (affects caching/retry behavior)
  @impl true
  def side_effect?, do: true

  # Cache results for 5 minutes
  @impl true
  def cache_ttl, do: :timer.minutes(5)

  # Cache key scope — same record ID returns cached result
  @impl true
  def cache_scope(args), do: args["record_id"]
end
```

| Callback | Default | Description |
|---|---|---|
| `call(action, args, ctx)` | *required* | Execute the tool action |
| `redact(args)` | passthrough | Strip sensitive/bulky data from args before journaling |
| `redact_result(result)` | passthrough | Strip bulky data from results before journaling |
| `side_effect?()` | `false` | Whether the action mutates external state |
| `cache_ttl()` | `:no_cache` | How long to cache results (ms) |
| `cache_scope(args)` | `""` | Cache key discriminator |

Register tools in config:

```elixir
config :cyclium, :capability_registry, %{
  data_source: MyApp.Tools.DataSource,
  notifier: MyApp.Tools.Notifier
}
```

Strategies invoke tools via
`{:tool_call, :data_source, :read_record, %{"record_id" => "R-123"}}`. The
`ToolExec` wrapper handles capability resolution, caching, redaction, and error
classification.

### Argument keys: prefer strings

`ToolExec` passes the `args` map to `call/3` **verbatim** — it does not normalize
string vs. atom keys. This is deliberate: tools see exactly what the strategy
sent, and the framework never silently creates atoms from external input. By
convention, **use string keys** (`args["record_id"]`). That's what LLM-driven
tool calls produce (JSON decodes to string keys), and it's the dominant
convention across existing tools, so a tool written for string keys works
identically whether the caller is the synthesizer or a hand-written `next_step`.

If a tool may be invoked both ways and you want to be lenient, read both
explicitly — `args["id"] || args[:id]` — rather than expecting the framework to
coerce. Don't `String.to_atom/1` incoming keys (untrusted input → atom-table
growth); if you must, `String.to_existing_atom/1`.

## Synthesizers

A **synthesizer** is the bridge between strategies and LLM infrastructure. It
implements `Cyclium.Synthesizer` and is called when a strategy returns
`{:synthesize, prompt_ctx}`. The synthesizer handles the actual LLM call, and its
response flows back through `handle_result/3`.

```elixir
defmodule MyApp.Synthesizers.ResourceAnalysis do
  @behaviour Cyclium.Synthesizer

  @impl true
  def synthesize(prompt_ctx, _episode_ctx) do
    case MyApp.LLM.chat(prompt_ctx.system, prompt_ctx.user) do
      {:ok, text} -> {:ok, %{text: text}}
      {:error, reason} -> {:error, :llm_error, reason}
    end
  end

  @impl true
  def estimate_tokens(prompt_ctx) do
    # Rough estimate for budget tracking
    String.length(prompt_ctx.user || "") |> div(4)
  end
end
```

### Attaching a synthesizer to an actor

Synthesizers can be declared at two levels:

**Actor-level** — inherited by all expectations in the actor that use
`:synthesize`. Declare it when most or all expectations share the same
synthesizer:

```elixir
defmodule MyApp.Actors.ResourceAdvisorActor do
  use Cyclium.Actor

  actor do
    domain(:resource_advisory)
    spec_rev("v0.1.0")
    synthesizer(MyApp.Synthesizers.ResourceAnalysis)
    max_concurrent_episodes(3)
    episode_overflow(:queue)

    expectation(:resource_advisory,
      strategy: MyApp.Strategies.ResourceAdvisor,
      trigger: {:event, "resource.advisory_requested"},
      budget: %{max_turns: 5, max_tokens: 10_000, max_wall_ms: 30_000}
    )

    expectation(:risk_assessment,
      strategy: MyApp.Strategies.ResourceRisk,
      trigger: {:event, "resource.risk_review_requested"},
      budget: %{max_turns: 8, max_tokens: 15_000, max_wall_ms: 60_000}
    )
  end
end
```

Both expectations above use `MyApp.Synthesizers.ResourceAnalysis`.

**Expectation-level** — overrides the actor-level synthesizer for a specific
expectation. Use this when one expectation needs a different model or
configuration:

```elixir
actor do
  domain(:resource_advisory)
  synthesizer(MyApp.Synthesizers.ResourceAnalysis)   # default for this actor

  expectation(:resource_advisory,
    strategy: MyApp.Strategies.ResourceAdvisor,
    trigger: {:event, "resource.advisory_requested"},
    synthesizer: MyApp.Synthesizers.FastSummary      # override for this expectation
  )

  expectation(:risk_assessment,
    strategy: MyApp.Strategies.ResourceRisk,
    trigger: {:event, "resource.risk_review_requested"}
    # uses ResourceAnalysis (inherited from actor)
  )
end
```

The strategy itself doesn't know or care which synthesizer is wired in — it just
returns `{:synthesize, prompt_ctx}` and receives the result in `handle_result`:

```elixir
def next_step(%{resource_data: data, ai_summary: nil}, _ctx) do
  {:synthesize, %{
    system: "You are an operations risk analyst.",
    user: "Resource: #{data.name}, #{data.used}/#{data.limit} used"
  }}
end

def handle_result(state, %{kind: :synthesis}, {:ok, %{text: text}}) do
  {:ok, %{state | ai_summary: text}}
end
```

**When you don't need a synthesizer:** If your strategy is purely deterministic
(like `ResourceLimits` above), you don't need to declare a synthesizer at all.
The synthesizer is only invoked when a strategy returns
`{:synthesize, prompt_ctx}` — if your strategy never does, the synthesizer
configuration is ignored.

### LLM-provided confidence

Findings have a `confidence` field (0.0–1.0). For deterministic strategies,
hardcoding `1.0` is fine. But when an LLM produces the assessment, you can ask it
to self-report confidence and pass that through to the finding.

**Step 1 — Add `confidence` to the tool schema in your synthesizer:**

```elixir
@tool_definition %{
  type: "function",
  function: %{
    name: "resource_assessment",
    parameters: %{
      type: "object",
      properties: %{
        class: %{type: "string", enum: ["healthy", "limit_risk", "over_limit"]},
        severity: %{type: "string", enum: ["low", "medium", "high", "critical"]},
        summary: %{type: "string", description: "One sentence status summary"},
        confidence: %{
          type: "number",
          minimum: 0.0,
          maximum: 1.0,
          description:
            "How confident you are in this assessment (0.0–1.0). " <>
            "Use lower values when data is sparse or ambiguous, " <>
            "higher values when the evidence clearly supports the classification."
        }
        # ... other fields
      },
      required: ["class", "severity", "summary", "confidence"]
    }
  }
}
```

The description matters — it tells the LLM what the scale means, which produces
more calibrated values than a bare `"confidence"` field.

**Step 2 — Read it in converge and pass it to the finding:**

```elixir
def converge(state, episode_ctx) do
  result = state.assessment
  confidence = parse_confidence(result["confidence"])

  {:ok, %ConvergeResult{
    classification: %{"primary" => result["class"]},
    confidence: confidence,
    summary: result["summary"],
    findings: [
      {:raise, %{
        finding_key: "resource:limits:#{state.resource_id}:#{episode_ctx.episode_id}",
        confidence: confidence,
        # ... other finding fields
      }}
    ]
  }}
end

defp parse_confidence(val) when is_number(val), do: max(0.0, min(val, 1.0))
defp parse_confidence(_), do: 0.5
```

The `parse_confidence/1` helper clamps to `[0.0, 1.0]` and falls back to `0.5` if
the LLM returns something unexpected. The same confidence flows into both the
`ConvergeResult` (episode-level) and the finding (queryable).

**When to hardcode instead:** If the classification is deterministic (rule-based,
no LLM), use `confidence: 1.0`. The LLM confidence pattern is for cases where the
assessment involves judgment — ambiguous data, sparse evidence, or nuanced
classification where the LLM's certainty is genuinely informative.

## Autonomous agentic episodes (`AgenticTask`)

Everything above keeps the **developer as the router** — your `next_step/2`
decides each action. Sometimes you want the opposite for a bounded task: hand
the LLM an objective and a tool allow-list and let *it* decide which tools to
call, in what order, until it's done — but with **no human conversation**, unlike
the [interactive template](interactive_actors.md). That's
`Cyclium.Strategy.Template.AgenticTask`.

It's the interactive intent loop —
`interpret → validate → execute → summarize → (loop | done)` — seeded from an
objective instead of a user message, and terminated by an explicit tool call
instead of a chat reply. The developer still owns the boundaries: the objective,
the allow-list, the budget, and what the episode converges into. The LLM only
gets to choose which permitted tools to call within that envelope. Both templates
share one implementation (`Cyclium.Strategy.Template.Agentic.Loop`).

Use it for autonomous, one-shot investigations — "review this resource and raise
a finding if it's over limit," "triage this alert and propose a notification" —
that fire from an event, schedule, or workflow rather than a chat turn.

```elixir
expectation(:review_resource,
  strategy: Cyclium.Strategy.Template.AgenticTask,
  trigger: [{:event, "resource.updated"}, :workflow],
  subject_key: :resource_id,
  synthesizer: {Cyclium.Synthesizer.Interactive, llm: MyApp.LLM},
  budget: %{max_turns: 30, max_tokens: 40_000, max_wall_ms: 120_000},
  strategy_config: %{
    objective:
      "Review resource {{resource_id}} and raise a finding if it is over its limit.",
    role: "You are an operations analyst.",
    guidelines: ["Gather evidence with read tools before concluding."],
    allowed_tool_signatures: [
      %{
        name: "resources",
        side_effect: "read",
        actions: [
          %{name: "lookup_resource", args: %{"resource_id" => "UUID"},
            description: "get full details for one resource"}
        ]
      }
    ]
  }
)
```

**The objective is static + payload.** The `objective` string is a template
interpolated with `{{key}}` / `{{a.b}}` placeholders resolved against the trigger
payload (`Event.payload`, `Workflow.input`, or `Manual`'s `reason`). An
unresolved placeholder becomes an empty string rather than crashing. A trigger
payload may also carry its own `"objective"` string, which overrides the static
template (and is still interpolated) — so the same expectation can run a fixed
task per event or a fully dynamic one handed in by the caller.

**Termination via `finish_agentic_task`.** A reserved tool by that name is
auto-injected into the tool menu (you don't declare it). When the model calls
it, the run ends and the tool's args become the converge result:

```json
{"tool": "finish_agentic_task", "action": "finish_agentic_task", "args": {
  "summary": "R-1 is 120% over its limit.",
  "confidence": 0.9,
  "findings": [{"action": "raise", "class": "over_limit", "severity": "high",
                "finding_key": "resource:limits:R-1", "summary": "Over allocated limit"}],
  "outputs":  [{"type": "slack", "dedupe_key": "r-1-over", "payload": {"text": "…"}}]
}}
```

`findings` and `outputs` use the same shapes `ConvergeResult` expects
(`{:raise, …}` / `{:clear, key, reason}` and `%OutputProposal{}`). If the model
instead stops with a plain-text answer, that text becomes the summary and the
episode converges without findings. The `finish_agentic_task` call is intercepted
*before* `PlanGate` — it never reaches a tool executor — so `finish_agentic_task`
is a **reserved name**; don't declare a real tool with it.

**Security is the allow-list.** With no human preview by default,
`allowed_tool_signatures` is the entire security boundary — keep it as narrow as
the task needs and prefer read-only signatures unless a write is genuinely
required. The [interactive-actors guide's Security
section](interactive_actors.md#security) applies verbatim: the LLM proposes, the
gate disposes. Give autonomous runs a generous `max_turns` (each gather →
summarize cycle is ~7 turns) since the token budget, not a fixed step count,
bounds a legitimate multi-tool loop.

---

**Related guides:** [Findings & Outputs](findings_and_outputs.md) ·
[Workflows](workflows.md) · [Observability](observability.md) ·
[Advanced](advanced.md) (checkpointing, retry, circuit breaker, dry runs, batch,
testing)

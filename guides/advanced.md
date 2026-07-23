# Advanced Topics

Reliability primitives and power-user features: checkpointing, circuit breakers,
step retry, the reconciler, dry runs / simulations, batch processing, and the
test kit.

> Examples use a generic **resource** domain.

## Checkpointing

Strategies can save state mid-episode for crash recovery. Return
`{:checkpoint, phase_name}` from `next_step/2` to persist the current state at a
milestone — typically just before an expensive or irreversible phase:

```elixir
def next_step(%{phase: :collecting} = state, _ctx) do
  {:tool_call, :data_source, :read_record, %{"record_id" => state.record_id}}
end

# All data gathered — checkpoint the milestone before the costly analysis phase.
def next_step(%{phase: :collected}, _ctx) do
  {:checkpoint, "collected"}
end

def next_step(%{phase: :analyzing} = state, _ctx) do
  {:tool_call, :analyzer, :run, %{"data" => state.data}}
end

# The runner hands the checkpoint to handle_result (symmetric with :observe), so
# advance the phase here. Returning {:checkpoint, _} *without* moving the state
# forward would re-invoke next_step unchanged and loop.
def handle_result(%{phase: :collected} = state, %{kind: :checkpoint}, {:ok, _phase}) do
  {:ok, %{state | phase: :analyzing}}
end
```

The checkpoint saves the full strategy state map to the
`cyclium_episode_checkpoints` table, then the runner calls `handle_result/3` with
a `%EpisodeStep{kind: :checkpoint}` step and `{:ok, phase_name}` — the same shape
as `:observe`, so the strategy transitions there. On resume, `EpisodeTask` loads
the latest checkpoint by `checkpoint_no` and passes it to the strategy — execution
continues from where it left off.

### Checkpoint schema versioning

If your strategy's state shape changes between deploys, register a checkpoint
schema to migrate old checkpoints forward:

```elixir
defmodule MyApp.Checkpoints.ResourceCheck do
  use Cyclium.CheckpointSchema, version: 2

  # Migrate from version 1 -> 2
  def migrate(1, state), do: {:ok, Map.put(state, :new_field, nil)}
  def migrate(2, state), do: {:ok, state}
end
```

Declare it on the expectation (preferred — keeps the schema next to the
strategy whose state it versions):

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  checkpoint_schema: MyApp.Checkpoints.ResourceCheck,
  ...
)
```

Or register in config, which takes precedence over the expectation declaration
(useful as a deploy-time override), keyed by `{actor_id, expectation_id}` or
`actor_id`:

```elixir
config :cyclium, :checkpoint_schemas, %{
  {"resource_monitor", "check_resource_limits"} => MyApp.Checkpoints.ResourceCheck
}
```

If migration fails, `EpisodeTask` falls back to a fresh `strategy.init/2` — the
episode restarts from scratch.

### When to checkpoint vs. restart

**Use checkpoints** when:

- The strategy accumulates state across many turns that would be expensive to
  recompute (multi-turn LLM conversations, progressive data aggregation)
- Steps have non-idempotent side effects that shouldn't be repeated

**Use restart (no checkpoint)** when:

- The strategy re-queries all data from the DB each turn (most monitoring/health
  strategies)
- Side effects are idempotent (findings upsert by key, outputs are deduplicated)
- Episodes are short (< a few minutes)

Most strategies don't need checkpoints — `recovery_policy: :restart` on the
expectation handles recovery by re-running the episode from scratch. See the
[Distributed Ops](distributed_ops.md) guide.

## Circuit breaker

Per-expectation circuit breaker prevents cascading failures when a tool or
external service is down. When consecutive episode failures exceed a threshold,
the circuit opens and rejects new episodes. After a cooldown period, one probe
episode is allowed through (half-open state) — if it succeeds, the circuit closes.

```elixir
expectation(:check_provider_api,
  strategy: MyApp.Strategies.ProviderCheck,
  trigger: {:event, "provider.updated"},
  circuit_breaker: %{
    threshold: 5,               # consecutive failures to trip
    half_open_after_ms: 60_000, # cooldown before probe
    cancel_in_flight: false     # cancel running episodes when circuit trips
  }
)
```

**States:** `:closed` (normal) → `:open` (rejecting) → `:half_open` (probe) →
`:closed`

**In-flight cancellation:** When `cancel_in_flight: true`, tripping the circuit
also cancels any running or blocked episodes for that actor + expectation,
preventing wasted work against a known-broken dependency.

**Scope:** Circuit breakers are node-local (ETS-backed). In a cluster, each node
tracks failures independently. This is intentional — a service might be
unreachable from one node but fine from another. For cluster-wide coordination,
combine with the Bus (circuit breaker events are broadcast).

Force-fired episodes bypass the circuit breaker check.

Query state: `Cyclium.CircuitBreaker.get_state(actor_id, expectation_id)`

## Step Retry Helper

`Cyclium.Strategy.Retry` provides a lightweight helper for retrying failed steps
within an episode. This is distinct from workflow-level retry
(`on_failure :step, :retry`) which retries entire episodes — the step retry helper
retries individual steps (e.g. a synthesis call) within a single episode run.

### The problem

When a strategy calls `:synthesize` and the LLM provider returns a transient error
(timeout, rate limit, 503), the strategy needs to retry. Without a helper, you'd
manually track attempt counts in the state map:

```elixir
# Without helper — manual retry tracking
def handle_result(state, %{kind: :synthesis}, {:error, _}) do
  if state[:synthesis_retries] < 3 do
    {:retry, Map.update(state, :synthesis_retries, 1, &(&1 + 1))}
  else
    {:abort, "synthesis_failed"}
  end
end
```

This is error-prone (forgetting to reset counters, tracking multiple step types,
off-by-one errors).

### Using `Cyclium.Strategy.Retry`

```elixir
alias Cyclium.Strategy.Retry

# On success — reset the counter so future failures get fresh attempts
def handle_result(state, %{kind: :synthesis}, {:ok, result}) do
  {:ok, state |> Retry.reset(:synthesis) |> Map.put(:assessment, result)}
end

# On failure — retry up to 3 times with 2-second backoff
def handle_result(state, %{kind: :synthesis} = step, {:error, _}) do
  case Retry.check(state, step, max_attempts: 3, backoff_ms: 2_000) do
    {:retry, new_state}              -> {:retry, new_state}
    {:give_up, _attempts, new_state} -> {:abort, "synthesis_failed_after_retries"}
  end
end
```

When `handle_result` returns `{:retry, state}`, the runner calls `do_loop` →
`next_step` again. The strategy should naturally re-emit the same step type (e.g.
`:synthesize`) since its phase/state hasn't changed — only the internal
`__retries` counter was updated.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_attempts` | `3` | Total attempts including the original |
| `:backoff_ms` | `0` | Milliseconds to sleep before retry |
| `:step_key` | `step.kind` | Key for tracking — use custom keys to track retries per tool name or phase |

### Custom step keys

Track retries separately for different tool calls within the same episode:

```elixir
def handle_result(state, %{kind: :tool_call, tool_name: tool} = step, {:error, _}) do
  case Retry.check(state, step, step_key: {:tool, tool}, max_attempts: 2) do
    {:retry, new_state}              -> {:retry, new_state}
    {:give_up, _attempts, new_state} -> {:ok, %{new_state | phase: :skip_tool}}
  end
end
```

### API reference

- `Retry.check(state, step, opts)` — returns `{:retry, state}` or
  `{:give_up, count, state}`
- `Retry.reset(state, key)` — clears the counter for one key (call on success)
- `Retry.reset_all(state)` — clears all retry tracking

### Retry layers summary

| Layer | Scope | Mechanism | Backoff | Limit |
|-------|-------|-----------|---------|-------|
| **Step retry** (`Strategy.Retry`) | Within one episode | `handle_result` returns `{:retry, state}` | Optional (`backoff_ms`) | `max_attempts` per step key |
| **Episode budget** | Within one episode | Runner checks `max_turns`, `max_tokens`, `max_wall_ms` | N/A | Budget exhaustion |
| **Workflow retry** (`on_failure`) | Across episodes | WorkflowEngine creates new episode | `backoff_ms` (default 5s) | `max_step_attempts` (default 3) |
| **Crash recovery** | After restart | `Recovery.sweep` re-enqueues or fails | N/A | One attempt per `recovery_policy` |

## Reconciler

The optional `Cyclium.Reconciler` watches for `spec.updated` Bus events and
reconciles running actors when their configuration changes at runtime:

- Sends updated config to actor GenServers
- Cancels timers for removed expectations
- Starts timers for newly added schedule expectations
- Identifies orphaned blocked episodes (expectation removed) and cancels them

Enable via config:

```elixir
config :cyclium, :reconciler, true
```

Or trigger manually:

```elixir
Cyclium.Reconciler.reconcile_actor(actor_pid, new_module)
```

## Dry Runs / Simulations

Dry runs let you test what an actor would do without producing real findings,
outputs, or side effects. Useful for validating agent configurations and "what
if" testing.

### How dry runs work

An episode with `mode: "dry_run"`:

- Runs the full strategy loop (same `next_step` → `handle_result` cycle)
- **Findings are NOT persisted** — but are journaled for inspection (optionally
  persistable with prefixed keys via `persist_findings` option)
- **Outputs are NOT delivered** — but output proposals are journaled
- **Tool calls and synthesis can be overridden** with mock responses
- **Steps are fully journaled** — complete audit trail of what *would have*
  happened
- **Episode is tagged** as `mode: "dry_run"` for filtering in UI and metrics

### Force-firing a dry run

```elixir
# Simplest: real tool calls and synthesis, skip persist
Cyclium.Episodes.force_fire("resource_monitor", "check_resource_limits",
  mode: :dry_run,
  trigger_payload: %{resource_id: 123}
)

# With mock overrides — skip real API calls
Cyclium.Episodes.force_fire("resource_monitor", "check_resource_limits",
  mode: :dry_run,
  trigger_payload: %{resource_id: 123},
  overrides: %{
    tool_overrides: %{"data_source.search_records" => [%{id: 1, status: "active"}]},
    synthesis_override: %{"class" => "healthy", "severity" => "low"}
  }
)
```

### Override resolution (layered)

Three sources of overrides, checked in priority order:

```
fire-time overrides > expectation-level DSL > real execution
```

1. **Fire-time overrides** — passed to `force_fire/3` as `:overrides` option
2. **Expectation-level DSL** — defined in the actor definition:

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: {:event, "resource.updated"},
  dry_run: [
    tool_overrides: %{
      {"data_source", "search_records"} => {:ok, %{records: []}}
    },
    synthesis_override: {:ok, %{"class" => "healthy"}}
  ]
)
```

3. **No overrides** — real tool calls and synthesis execute normally, only
   findings and outputs are skipped

### Persisting findings in dry runs

By default, dry run findings are journaled but not persisted to the DB. You can
opt in to persistence with prefixed keys so dry run findings don't collide with
live ones:

```elixir
# Persist with default "dry_run" prefix (finding_key becomes "dry_run:resource:limits:R-123")
Cyclium.Episodes.force_fire("resource_monitor", "check_resource_limits",
  mode: :dry_run,
  overrides: %{persist_findings: true}
)

# Persist with custom prefix (finding_key becomes "experiment1:resource:limits:R-123")
Cyclium.Episodes.force_fire("resource_monitor", "check_resource_limits",
  mode: :dry_run,
  overrides: %{persist_findings: "experiment1"}
)
```

The prefix is also applied to `actor_id` on persisted findings, so
`Findings.active_for(actor: "resource_monitor")` won't return dry run findings —
use `Findings.active_for(actor: "dry_run:resource_monitor")` instead, or use the
mode-aware helper:

```elixir
# Automatically prefixes filters when episode is a dry run with persist_findings enabled:
Cyclium.Findings.active_for_mode([actor: "resource_monitor"], episode)
```

This can also be set at the expectation level in the actor DSL:

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: {:schedule, 300_000},
  dry_run: [persist_findings: true]
)
```

### Via the Actor GenServer

You can also fire dry runs through the actor's message interface:

```elixir
GenServer.cast(MyApp.Actors.ResourceMonitor, {:force_fire, :check_resource_limits, mode: :dry_run})
```

### Dry run results

The episode completes with full step journal. In the UI:

- "DRY RUN" badge on the episode
- Step timeline shows which steps used mock overrides (`_dry_run: true` in
  result_ref)
- Findings show what *would have* been created
- Full step-by-step debugging available

### Workflow dry runs

Workflows support dry run mode — every step episode inherits the mode and opts
from the workflow instance:

```elixir
# Compiled workflow
WorkflowEngine.start_workflow(MyWorkflow, trigger_data, mode: :dry_run)

# Dynamic workflow with finding persistence
WorkflowEngine.start_dynamic_workflow("resource_provisioning", trigger_data,
  mode: :dry_run,
  dry_run_opts: %{persist_findings: true}
)
```

All step episodes will run in dry run mode: findings are journaled (and optionally
persisted with prefix), outputs are skipped. The workflow instance itself stores
`mode` and `dry_run_opts` (V9 migration), so retries and subsequent steps also
inherit the mode.

Per-step overrides allow targeting different mocks and options to individual
steps:

```elixir
WorkflowEngine.start_dynamic_workflow("resource_provisioning", trigger_data,
  mode: :dry_run,
  dry_run_opts: %{
    persist_findings: true,
    steps: %{
      "validate" => %{
        "synthesis_override" => %{"class" => "high_risk", "severity" => "high"}
      },
      "provision" => %{
        "tool_overrides" => %{"data_source.create_record" => %{"id" => "mock-r-001"}},
        "persist_findings" => "experiment1"
      }
    }
  }
)
```

Global keys (like `persist_findings: true`) apply to all steps. Step-specific keys
override globals for that step. The `"steps"` key itself is stripped from each
episode's opts.

Strategies in workflow steps can use `Findings.active_for_mode/3` to transparently
query their own dry run findings when `persist_findings` is enabled.

## Batch helpers and per-item episodes

When a single episode needs to process many items in groups, `Cyclium.Batch`
helps. But it's not the only pattern — firing one episode per item (driven by
domain events) is often a better fit. This section covers both and when to use
each.

### Batch helpers

`Cyclium.Batch` provides a lightweight struct for strategies that process data in
grouped batches across multiple `:synthesize` calls. No new step types —
strategies continue using `:tool_call` and `:synthesize` as normal.

```elixir
# Group items semantically (e.g., by base item so variants are compared together)
groups = Cyclium.Batch.group_by(items, & &1.base_item_id)
batch = Cyclium.Batch.init(groups)

# Or chunk by fixed size
batch = items |> Cyclium.Batch.chunk(10) |> Cyclium.Batch.init()
```

In `next_step`, drive the loop:

```elixir
case Cyclium.Batch.current_group(state.batch) do
  nil -> :converge  # all groups processed
  {group_key, items} -> {:synthesize, build_prompt(group_key, items)}
end
```

In `handle_result`, advance:

```elixir
batch = Cyclium.Batch.advance(state.batch, parsed_result)
{:ok, %{state | batch: batch}}
```

Progress tracking via `Batch.group_count/1`, `Batch.processed_count/1`, and
`Batch.done?/1`.

### Per-item episodes vs. batch processing

An alternative to batching is to **fire one episode per item**, driven by domain
events.

| Approach | When to use | Episode count |
|---|---|---|
| Batch (single episode) | Scheduled sweep over a large dataset; items need cross-comparison | One episode, many `:synthesize` turns |
| Per-item (many episodes) | Event-driven re-evaluation; each item is independent | One episode per item |

**Per-item pattern — ResourceMonitor:**

The actor listens for `"resource.updated"` events. Each event carries a
`resource_id`, and each resource gets its own independent episode. There's no need
to load the full dataset — the trigger tells you which item changed.

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
      debounce_ms: :timer.seconds(2),
      budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}
    )
  end
end
```

The strategy is single-turn — load the item, classify it deterministically, emit
findings:

```elixir
defmodule MyApp.Strategies.ResourceLimits do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, trigger) do
    {:ok, %{resource_id: trigger.payload["resource_id"]}}
  end

  @impl true
  def next_step(_state, _episode_ctx), do: :converge

  @impl true
  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, episode_ctx) do
    resource = MyApp.Resources.get!(state.resource_id)
    percent_used = resource.used / max(resource.limit, 1)

    {class, severity, summary} = classify(resource.status, percent_used)

    {:ok, %Cyclium.ConvergeResult{
      classification: %{"primary" => class, "severity" => to_string(severity)},
      confidence: 1.0,
      summary: summary,
      findings: [
        {:raise, %{
          actor_id: "resource_monitor",
          finding_key: "resource:limits:#{resource.id}:#{episode_ctx.episode_id}",
          class: class,
          severity: severity,
          confidence: 1.0,
          subject_kind: "resource",
          subject_id: resource.id,
          summary: summary,
          evidence_refs: %{"percent_used" => percent_used}
        }}
      ],
      outputs: []
    }}
  end

  defp classify(:decommissioned, _pct), do: {"decommissioned", :low, "Resource decommissioned"}
  defp classify(_s, pct) when pct > 1.0, do: {"over_limit", :high, "Over allocated limit"}
  defp classify(_s, pct) when pct > 0.85, do: {"limit_risk", :medium, "Approaching limit"}
  defp classify(_s, _pct), do: {"healthy", :low, "Within limits"}
end
```

**Why this works well:**

- **Reactive** — evaluation happens the moment data changes, not on a polling
  schedule
- **Isolated** — each resource gets its own episode with its own budget, journal,
  and findings
- **Backpressure built in** — `max_concurrent_episodes` + `debounce_ms` +
  `subject_key` prevent a burst of updates from overwhelming the system. Rapid
  updates to the same resource coalesce into one episode
- **Findings create an audit trail** — the episode-scoped `finding_key`
  (`"resource:limits:#{id}:#{episode_id}"`) means each evaluation produces its own
  finding, giving you a point-in-time history of how status evolved. Note this is
  the *distinct-per-episode* keying: these findings accumulate and are never
  cleared by later runs, so bound them with a `ttl_seconds` or archival. For
  ongoing status (one active finding per subject, updated each run) use a stable
  key instead — see [Finding key scoping](findings_and_outputs.md#finding-key-scoping-deduplicated-vs-distinct).

**When to reach for Batch instead:** If you need to process 500 items in one pass
(e.g., a nightly classification sweep), a single episode with `Cyclium.Batch` is
more efficient than 500 separate episodes — fewer rows, one journal, and the
ability to compare items within groups.

## Test kit

Cyclium ships a test kit in `Cyclium.Test.*` that host apps can use to smoke-test
their definitions without running full episodes. Import the helpers with `use`:

### Actor validation

```elixir
defmodule MyApp.Actors.ResourceMonitorTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.ActorCase

  test "actor definition is valid" do
    assert_valid_actor(MyApp.Actors.ResourceMonitor)
  end

  test "all expectations have strategies" do
    assert_strategies_defined(MyApp.Actors.ResourceMonitor)
  end

  test "budgets are well-formed" do
    assert_budgets_valid(MyApp.Actors.ResourceMonitor)
  end

  test "spec_rev is set" do
    assert_spec_rev_set(MyApp.Actors.ResourceMonitor)
  end
end
```

### Strategy contract verification

```elixir
defmodule MyApp.Strategies.ResourceLimitsTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.StrategyCase

  @episode build_test_episode(actor_id: "resource_monitor", expectation_id: "check_resource_limits")
  @trigger %Cyclium.Trigger.Manual{requested_by: "test"}

  test "init returns valid state" do
    assert_valid_init(MyApp.Strategies.ResourceLimits, @episode, @trigger)
  end

  test "strategy terminates within budget" do
    assert_strategy_terminates(MyApp.Strategies.ResourceLimits, @episode, @trigger,
      max_steps: 20
    )
  end
end
```

### Synthesizer testing

```elixir
use Cyclium.Test.SynthesizerCase

# Contract validation
assert_valid_synthesize(MySynthesizer, prompt_ctx, episode_ctx)
assert_valid_estimate_tokens(MySynthesizer, prompt_ctx)

# FakeSynthesizer for strategy tests
{:ok, _} = Cyclium.Test.FakeSynthesizer.start_link()
Cyclium.Test.FakeSynthesizer.set_response(%{"answer" => "42"})
# ... run strategy, then inspect calls:
Cyclium.Test.FakeSynthesizer.calls()
```

### Output adapter testing

```elixir
use Cyclium.Test.OutputCase

# Contract validation
assert_valid_deliver(MyApp.Adapters.Slack, :slack, payload, ctx)

# FakeOutputAdapter for integration tests
{:ok, _} = Cyclium.Test.FakeOutputAdapter.start_link()
# ... run episode, then inspect deliveries:
Cyclium.Test.FakeOutputAdapter.deliveries()
```

### Workflow validation

```elixir
defmodule MyApp.Workflows.ResourceProvisioningTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.WorkflowCase

  test "workflow is valid" do
    assert_valid_workflow(MyApp.Workflows.ResourceProvisioning)
  end

  test "all steps have failure policies" do
    assert_failure_policies_complete(MyApp.Workflows.ResourceProvisioning)
  end

  test "step inputs don't crash" do
    assert_step_inputs_safe(MyApp.Workflows.ResourceProvisioning,
      trigger: %{"resource_id" => "r123"}
    )
  end
end
```

### Checkpoint migration fuzzing

Property-based testing for `migrate/2` chains using StreamData:

```elixir
use Cyclium.Test.CheckpointMigration

# Fuzz test: generate random states, migrate through version chain, assert no crashes
assert_migration_safe(MyCheckpoint, iterations: 200)

# Specific version migration
assert_migration(MyCheckpoint, %{"old_field" => 1}, 1, 3)

# Idempotency: migrating an already-current state is a no-op
assert_migration_idempotent(MyCheckpoint, iterations: 100)
```

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Workflows](workflows.md) · [Distributed Ops](distributed_ops.md)

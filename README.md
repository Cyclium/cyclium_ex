# Cyclium

[![Hex.pm](https://img.shields.io/hexpm/v/cyclium.svg)](https://hex.pm/packages/cyclium)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/cyclium)

> **Autonomous agent framework for Elixir** — actors monitor domains, run
> multi-turn episodes with budget enforcement, and produce persistent findings
> and typed outputs.

Cyclium is an Elixir library for building agentic systems that monitor domains,
run multi-turn episodes, classify situations, and produce typed outputs. Actors
declare expectations — named, triggerable processes; when a trigger fires, an
episode executes the expectation's strategy, which can gather data, call tools,
synthesize with LLMs, and converge into findings and outputs. Think of it as an
OTP-native agent framework where the episode — not the request — is the unit of
work.

The **developer is the router**: your `next_step/2` is a deterministic state
machine that decides what happens next. The LLM is a tool you call at specific
points via `:synthesize`, never the control plane — so you get repeatability,
testability, and full visibility while still using AI where it adds value. See
[Actors & Strategies](guides/actors_and_strategies.md) for the full philosophy.

## Key features

- **Declarative Actor DSL** — Define actors, expectations, triggers, and budgets in a compact macro-based syntax
- **Strategy Pattern** — Pluggable investigation logic with a clear init → observe → converge lifecycle
- **Episode Runner** — Budget-enforced execution loop with step journaling, checkpointing, and crash recovery
- **Findings Lifecycle** — Persistent observations with raise/update/clear semantics, upsert-by-key, causality chains, TTL expiration, severity escalation, and post-raise enrichment hooks
- **Output Router** — Deduplicated, adapter-based delivery (email, Slack, webhooks) with approval gates and adapter registry
- **Event Bus** — Phoenix.PubSub-backed event system connecting actors without coupling
- **Workflow Engine** — Multi-actor coordination with dependency graphs, failure policies, retry with backoff, cross-workflow episode dedup, and cancellation cascade
- **Circuit Breaker** — Per-expectation circuit breaker with configurable thresholds, half-open recovery, and optional in-flight episode cancellation
- **Episode Sampling** — Probabilistic firing control via `sample_rate` on expectations
- **Service Level Tracking** — Declarative performance objectives with breach detection and telemetry
- **Adaptive Budgets** — Advisory budget recommendations based on historical episode usage (p95 with headroom)
- **Backpressure Controls** — Per-actor concurrency limits with queue, drop, or shed-oldest overflow policies
- **Debounce and Cooldown** — Temporal controls to coalesce rapid-fire events and enforce minimum gaps
- **Log Projection** — Materialized human-readable logs at configurable verbosity (none → full_debug)
- **Telemetry** — 36 structured telemetry events for observability
- **OTP-Native** — No Oban or external job queue required; episodes run as Tasks under DynamicSupervisor
- **Distributed coordination** — DB-based dedup, lease-based work claims, crash recovery, and multi-stack/trigger-only deployment modes — no Redis or leader election
- **Test Kit** — Assertion macros and fakes for validating actors, strategies, synthesizers, output adapters, workflows, and checkpoint migrations in host apps
- **SQL Server 2017 Compatible** — Transaction-based upserts, denormalized query columns, no JSON operators in DDL

## Who is this for?

Cyclium is designed for Elixir teams building **autonomous agent systems** where:

- Recurring evaluations run on events or schedules (SLAs, health checks, compliance checks)
- Episodes involve multiple steps: data gathering, LLM synthesis, tool calls, human approval
- Findings need to persist and evolve over time (raised → updated → cleared)
- Actions need deduplication, audit trails, and typed delivery through adapters
- Multiple actors need to coordinate through workflows with dependency ordering
- Real-time visibility into agent state is essential (Phoenix LiveView integration via Bus)

If you need a simple cron job or a one-shot script, Cyclium is overkill. Cyclium
shines when you have ongoing, stateful processes that produce findings and
outputs — and need the lifecycle, audit trail, and coordination to go with them.

## How Cyclium differs

- **vs. Oban** — Oban is a job queue: enqueue work, run it, done. Cyclium manages
  stateful, multi-turn episodes with budgets, findings, outputs, and workflows.
  Episodes happen to run as OTP Tasks, so you don't need Oban — but the two solve
  different problems and can be used together.
- **vs. chat-agent frameworks** — Those are built for interactive, LLM-routed
  conversations. Cyclium is built for autonomous operational agents that monitor
  domains and act, with or without an LLM in the loop, under deterministic
  developer control.
- **vs. raw GenServers** — You could build all of this yourself, but Cyclium
  gives you the episode lifecycle, findings system, output router, workflow
  engine, and event bus — wired together with telemetry and audit trails.

## Architecture

> The guides use a generic **resource monitoring** example: a `ResourceMonitor`
> actor that evaluates a resource's usage against a limit and classifies status,
> plus a `ResourceAdvisorActor` that produces an LLM-powered summary.

### Supervision tree

```
YourApp.Supervisor
├── YourApp.Repo
├── Phoenix.PubSub
├── YourApp.Actors.ResourceMonitor (GenServer)
├── YourApp.Actors.ResourceAdvisorActor (GenServer)
├── Cyclium.Supervisor
│   ├── Cyclium.ActorSupervisor (DynamicSupervisor)
│   ├── Cyclium.EpisodeSupervisor (DynamicSupervisor)
│   │   └── Cyclium.EpisodeTask (one per running episode)
│   ├── Cyclium.TaskSupervisor (Task.Supervisor)
│   ├── Cyclium.Reconciler (optional — spec change detection)
│   ├── Cyclium.WorkflowEngine (optional — multi-actor workflows)
│   └── Cyclium.Findings.FindingSweep (optional — expiration + escalation)
└── YourAppWeb.Endpoint
```

**Actors** are GenServers that subscribe to Bus events and manage episode
lifecycle. They're started by the consuming app's supervision tree, above
Cyclium's supervisors. When a trigger fires, the actor creates an Episode row and
starts an `EpisodeTask` under the `EpisodeSupervisor`. Each task resolves a
strategy from the registry and runs the episode loop.

**Key design principles:**

- Actors own concurrency limits — they track active/queued episodes in-process
- Episodes are durable — the `cyclium_episodes` table is itself a work queue
- The Bus connects everything — actors, LiveViews, and workflows all subscribe to the same event stream
- Strategies are stateless modules — all state lives in the episode's strategy state map

### Execution model

```
Bus event arrives
  → Actor.handle_info matches expectation trigger
  → Check debounce/cooldown → circuit breaker → sample_rate
  → Check concurrency (active < max?)
    → yes: create Episode row, start EpisodeTask under DynamicSupervisor
    → no:  apply overflow policy (queue / drop / shed_oldest)

EpisodeTask starts
  → Resolve strategy (persistent_term registration from actor boot → registry override)
  → strategy.init(episode, trigger)
  → EpisodeRunner.execute_loop:

    ┌─────────────────────────────────────────────┐
    │  check_budget → check_loop → increment_turn │
    │  strategy.next_step(state, ctx)             │
    │    :done         → journal, set done        │
    │    :converge     → run converge pipeline    │
    │    {:tool_call}  → exec tool, handle_result │
    │    {:observe}    → journal, handle_result   │
    │    {:synthesize} → journal, handle_result   │
    │    {:checkpoint} → save state, loop         │
    │    {:approval}   → block, wait for human    │
    │    {:wait}       → block, wait for external │
    │    ...           → loop                     │
    └─────────────────────────────────────────────┘

  Converge pipeline (post_converge):
    1. Persist findings (raise/update/clear) → enrich → Bus events per finding
    2. Route outputs through adapters → dedup by dedupe_key, deliver
    3. Compute final episode status from delivery outcomes
    4. Journal completion/failure step
    5. Project log via LogProjector
    6. Record service levels + check for breach
    7. Record adaptive budget sample (if enabled)
    8. Broadcast episode.completed/failed on Bus
    9. Emit telemetry
```

## Core concepts

| Concept | What it is |
|---|---|
| **Actor** | A GenServer that owns expectations and fires episodes when triggers match. → [Actors & Strategies](guides/actors_and_strategies.md) |
| **Expectation** | A named, triggerable process — binds a trigger to a strategy and budget |
| **Strategy** | The brain of an episode — a stateless `init → next_step → handle_result → converge` module |
| **Episode** | One execution of a strategy, with budget tracking, a step journal, and a status lifecycle |
| **Finding** | A persistent observation with raise/update/clear semantics. → [Findings & Outputs](guides/findings_and_outputs.md) |
| **Output** | A typed proposal delivered through deduplicated adapters |
| **Bus** | A Phoenix.PubSub event stream connecting actors, LiveViews, and workflows |
| **Workflow** | Multi-actor coordination over a dependency graph. → [Workflows](guides/workflows.md) |

## Guides

| Guide | Covers |
|---|---|
| [Actors & Strategies](guides/actors_and_strategies.md) | Actor DSL, expectation options, strategy lifecycle, multi-turn strategies, episodes, budgets, deduplication, tools, synthesizers |
| [Findings & Outputs](guides/findings_and_outputs.md) | Findings lifecycle, causality chains, TTL/escalation/enrichment, output router & adapters, Bus events, LiveView, Window helpers |
| [Workflows](guides/workflows.md) | Compiled and dynamic (DB-defined) workflows, data passing, failure policies |
| [Dynamic Actors](guides/dynamic_actors.md) | DB-stored actor definitions, strategy templates, gatherers, lifecycle & draining |
| [Observability](guides/observability.md) | Log strategies, synthesis storage pipeline, telemetry, step journal, sampling, service levels, adaptive budgets |
| [Distributed Ops](guides/distributed_ops.md) | Crash recovery, work claims, node identity, multi-stack deployments, trigger-only mode |
| [Advanced](guides/advanced.md) | Checkpointing, circuit breaker, step retry, reconciler, dry runs, batch & per-item processing, test kit |
| [Interactive Actors](guides/interactive_actors.md) | Human-in-the-loop episodes (approvals, waits) |
| [Conversation UI](guides/conversation_ui.md) | Building conversational front-ends over Cyclium |

## Setup

### 1. Add dependency

```elixir
# mix.exs
def deps do
  [{:cyclium, "~> 0.1.7"}]
end
```

Dependencies pulled in: `ecto`, `ecto_sql`, `jason`, `phoenix_pubsub`.

### 2. Run migrations

Each schema version is dispatched by passing its number to
`Cyclium.Migrations.up(version: n)` / `down(version: n)` — no need to name the
`V<n>` modules. For a **fresh install**, run every version in order via
`versions/0` (this list stays current as new versions ship):

```elixir
# In a migration file:
defmodule MyApp.Repo.Migrations.InstallCyclium do
  use Ecto.Migration

  def up do
    Enum.each(Cyclium.Migrations.versions(), &Cyclium.Migrations.up(version: &1))
  end

  def down do
    Cyclium.Migrations.versions()
    |> Enum.reverse()
    |> Enum.each(&Cyclium.Migrations.down(version: &1))
  end
end
```

When **upgrading** an existing install, add one migration file per new version
(so Ecto tracks each independently):

```elixir
defmodule MyApp.Repo.Migrations.CycliumV22 do
  use Ecto.Migration
  def up, do: Cyclium.Migrations.up(version: 22)
  def down, do: Cyclium.Migrations.down(version: 22)
end
```

See the [Interactive Actors guide](guides/interactive_actors.md) for the
per-version-file template.

> **Authoring migrations:** do not use bare `:text`. On `Ecto.Adapters.Tds` it
> emits SQL Server's legacy non-Unicode `TEXT` type, which silently replaces
> emoji and other non-CP1252 characters with `?`. Use `{:string, size: :max}`
> (which becomes `nvarchar(max)` on Tds and `TEXT` on Postgres/SQLite), or
> branch on `repo().__adapter__()` for finer control. V19 is the one-shot
> repair migration for columns that were already declared `:text`.

### 3. Configure

```elixir
# config.exs
config :cyclium, :repo, MyApp.Repo

# Optional: registry for strategy/synthesizer overrides (see Actors & Strategies guide)
# config :cyclium, :strategy_registry, MyApp.StrategyRegistry

# Optional: episode runner (default: Cyclium.Runner.OTP)
# Use Cyclium.Runner.Deferred for trigger-only mode (see Distributed Ops guide)
config :cyclium, :runner, Cyclium.Runner.OTP

# Optional: node identity override for shared-name environments (see Distributed Ops guide)
# config :cyclium, :node_identity, "my-unique-node-name"

# Optional: tool capabilities
config :cyclium, :capability_registry, %{
  data_source: MyApp.Tools.DataSource,
  notifier: MyApp.Tools.Notifier
}

# Optional: output adapters
config :cyclium, :output_adapters, %{
  email: MyApp.Adapters.Email,
  slack: MyApp.Adapters.Slack
}

# Optional: checkpoint schemas for versioned state migration
config :cyclium, :checkpoint_schemas, %{
  {"resource_monitor", "check_resource_limits"} => MyApp.Checkpoints.ResourceCheck
}

# Optional: enable reconciler for hot spec changes
config :cyclium, :reconciler, true

# Optional: register workflows
config :cyclium, :workflows, [MyApp.Workflows.ResourceReview]
```

### 4. Declare strategies on expectations

The preferred approach is declaring the strategy module directly on each
expectation in the actor DSL. Cyclium registers the mapping automatically when the
actor GenServer boots — no separate registry needed:

```elixir
defmodule MyApp.Actors.ResourceMonitor do
  use Cyclium.Actor

  actor do
    domain(:resource)
    spec_rev("v0.1.0")
    synthesizer(MyApp.Synthesizers.ResourceAnalysis)  # actor-level default
    max_concurrent_episodes(5)
    episode_overflow(:queue)

    expectation(:check_resource_limits,
      strategy: MyApp.Strategies.ResourceLimits,
      trigger: {:event, "resource.updated"},
      subject_key: :resource_id,
      debounce_ms: :timer.seconds(3),
      budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}
    )

    expectation(:resource_advisory,
      strategy: MyApp.Strategies.ResourceAdvisor,
      synthesizer: MyApp.Synthesizers.FastSummary,  # override for this expectation
      trigger: {:event, "resource.advisory_requested"},
      budget: %{max_turns: 5, max_tokens: 5_000, max_wall_ms: 60_000}
    )
  end
end
```

See the [Actors & Strategies guide](guides/actors_and_strategies.md) for the
optional strategy registry used for environment/A-B overrides.

### 5. Supervision tree

```elixir
# application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Cyclium.Supervisor, pubsub: MyApp.PubSub},
  MyApp.Actors.ResourceMonitor,
  MyApp.Actors.ResourceAdvisorActor,
  MyAppWeb.Endpoint
]
```

`Cyclium.Supervisor` starts the DynamicSupervisors, TaskSupervisor, and optionally
the Reconciler and WorkflowEngine.

## Database tables

All tables use `binary_id` primary keys and are SQL Server 2017 compatible (no
JSON operators in DDL, application-layer upserts, denormalized columns for indexed
queries).

| Table | Migration | Purpose |
|---|---|---|
| `cyclium_episodes` | V1 | Episode lifecycle, budget tracking, classification |
| `cyclium_episode_steps` | V1 | Step-by-step journal (16 step kinds) |
| `cyclium_episode_checkpoints` | V1 | Versioned strategy state snapshots |
| `cyclium_findings` | V1 | Persistent observations with raise/update/clear lifecycle |
| `cyclium_outputs` | V1 | Output proposals, delivery status, deduplication |
| `cyclium_episode_logs` | V2 | Materialized human-readable logs |
| `cyclium_workflow_instances` | V3, V9 | Workflow execution tracking, step states, dry run mode |
| `cyclium_work_claims` | V6 | Lease-based distributed work coordination |
| `cyclium_agent_definitions` | V7 | DB-stored actor definitions for dynamic actors |
| `cyclium_workflow_definitions` | V8 | DB-stored workflow definitions for dynamic workflows |
| `cyclium_trigger_requests` | V14 | Deferred episode execution for trigger-only nodes |

V4 adds `archived_at` to episodes and findings. V5 replaces the non-unique
`dedupe_key` index on episodes with a filtered unique index
(`WHERE dedupe_key IS NOT NULL AND archived_at IS NULL`) for multi-node
coordination. V6 adds the `cyclium_work_claims` table. V7 adds
`cyclium_agent_definitions` and `mode`/`dry_run_opts` columns to episodes. V8 adds
`cyclium_workflow_definitions`. V10 adds `caused_by_key` (finding causality
chains) and `expires_at` (TTL-based expiration) to `cyclium_findings`.

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Dialyzer (static analysis)
mix dialyzer

# Compile
mix compile --warnings-as-errors
```

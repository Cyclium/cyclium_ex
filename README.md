# Cyclium

> **Expectation-driven autonomous agents** — declare what should be true, act when reality diverges.

Cyclium is an Elixir library for building agentic systems that monitor domains, run multi-turn episodes, classify situations, and produce typed outputs. Actors declare expectations about how things should be; when triggers fire, episodes execute strategies that can gather data, call tools, synthesize with LLMs, and converge into findings and outputs. Think of it as an OTP-native agent framework where the episode — not the request — is the unit of work.

## Key features

- **Declarative Actor DSL** — Define actors, expectations, triggers, and budgets in a compact macro-based syntax
- **Strategy Pattern** — Pluggable investigation logic with a clear init → observe → converge lifecycle
- **Episode Runner** — Budget-enforced execution loop with step journaling, checkpointing, and crash recovery
- **Findings Lifecycle** — Persistent observations with raise/update/clear semantics and upsert-by-key
- **Output Router** — Deduplicated, adapter-based delivery (email, Slack, webhooks) with approval gates
- **Event Bus** — Phoenix.PubSub-backed event system connecting actors without coupling
- **Workflow Engine** — Multi-actor coordination with dependency graphs, failure policies, and retry with backoff
- **Backpressure Controls** — Per-actor concurrency limits with queue, drop, or shed-oldest overflow policies
- **Debounce and Cooldown** — Temporal controls to coalesce rapid-fire events and enforce minimum gaps
- **Log Projection** — Materialized human-readable logs at configurable verbosity (none → full_debug)
- **Telemetry** — 28 structured telemetry events for observability
- **OTP-Native** — No Oban or external job queue required; episodes run as Tasks under DynamicSupervisor
- **SQL Server 2017 Compatible** — Transaction-based upserts, denormalized query columns, no JSON operators in DDL

## Who is this for?

Cyclium is designed for Elixir teams building **autonomous agent systems** where:

- Business rules define what *should* be true (SLAs, health thresholds, compliance checks)
- Episodes involve multiple steps: data gathering, LLM synthesis, tool calls, human approval
- Findings need to persist and evolve over time (raised → updated → cleared)
- Actions need deduplication, audit trails, and typed delivery through adapters
- Multiple actors need to coordinate through workflows with dependency ordering
- Real-time visibility into agent state is essential (Phoenix LiveView integration via Bus)

If you need a simple cron job or a one-shot script, Cyclium is overkill. Cyclium shines when you have ongoing, stateful processes that produce findings and outputs — procurement monitoring, customer health scoring, compliance auditing, infrastructure drift detection, or even structured conversational workflows.

## How Cyclium differs

**vs. Oban** — Oban is a job queue: enqueue work, run it, done. Cyclium is an agent framework that manages stateful, multi-turn episodes with budgets, findings, outputs, and workflows. Episodes happen to run as OTP Tasks, so you don't need Oban — but the two solve different problems. You could use both: Oban for fire-and-forget jobs, Cyclium for ongoing autonomous processes.

**vs. Sagents** — Sagents is built for interactive AI conversations where users chat with LLM-powered agents in real time. Cyclium is built for autonomous operational agents that monitor domains, classify situations, and act — with or without an LLM in the loop. Cyclium's strategies can call LLMs via `:synthesize`, but they can also run purely deterministic logic. The execution model (expectations → episodes → findings → outputs) is designed for operational workflows, not chat.

**vs. GenServers / custom OTP** — You could build all of this with raw GenServers, but Cyclium gives you the episode lifecycle (budgets, journaling, checkpoints, crash recovery), the findings system (upsert-by-key, severity, evidence), the output router (deduplication, adapters, approval gates), the workflow engine (dependency graphs, failure policies), and the event bus — all wired together with telemetry and audit trails.

## Strategy-driven vs. LLM-routed

Most agent frameworks put the LLM in the driver's seat — it decides which tool to call, when to stop, and how to recover from errors. Cyclium inverts this. The **developer is the router**: your `next_step/2` function is a deterministic state machine that decides what happens next. The LLM is a powerful tool you call at specific points via `:synthesize`, but it never controls the flow.

This means you can mix deterministic and AI-powered steps in a single episode — gather data with a tool call, classify it with an LLM, then act on the result with another tool call — all under explicit developer control with budget enforcement at every turn:

```elixir
def next_step(%{phase: :gather} = state, _ctx) do
  {:tool_call, :erp_read, :search_pos, %{status: "STALLED"}}
end
def next_step(%{phase: :classify, po_data: data} = state, _ctx) do
  {:synthesize, %{task: :classify_po, data: data}}
end
def next_step(%{phase: :act, classification: "vendor_delay"} = state, _ctx) do
  {:tool_call, :email_write, :send_followup, build_email(state)}
end
```

The LLM is powerful, but it's not the control plane. You get repeatability, testability, and full visibility into exactly which steps ran and why — without sacrificing the ability to use AI where it adds value.

## Architecture

> The examples throughout this README use a **client health monitoring** system: a `ClientHealthActor` that evaluates client metrics (MRR, active users, support tickets) on each change and classifies health status, plus a `ClientAdvisorActor` that synthesizes an LLM-powered summary. See the [demo application](#demo-application) for the full working implementation.

### Supervision tree

```
YourApp.Supervisor
├── YourApp.Repo
├── Phoenix.PubSub
├── YourApp.Actors.ClientHealthActor (GenServer)
├── YourApp.Actors.ClientAdvisorActor (GenServer)
├── Cyclium.Supervisor
│   ├── Cyclium.ActorSupervisor (DynamicSupervisor)
│   ├── Cyclium.EpisodeSupervisor (DynamicSupervisor)
│   │   └── Cyclium.EpisodeTask (one per running episode)
│   ├── Cyclium.TaskSupervisor (Task.Supervisor)
│   ├── Cyclium.Reconciler (optional — spec change detection)
│   └── Cyclium.WorkflowEngine (optional — multi-actor workflows)
└── YourAppWeb.Endpoint
```

**Actors** are GenServers that subscribe to Bus events and manage episode lifecycle. They're started by the consuming app's supervision tree, above Cyclium's supervisors. When a trigger fires, the actor creates an Episode row and starts an `EpisodeTask` under the `EpisodeSupervisor`. Each task resolves a strategy from the registry and runs the episode loop.

**Key design principles:**
- Actors own concurrency limits — they track active/queued episodes in-process
- Episodes are durable — the `cyclium_episodes` table is itself a work queue
- The Bus connects everything — actors, LiveViews, and workflows all subscribe to the same event stream
- Strategies are stateless modules — all state lives in the episode's strategy state map

### Execution model

```
Bus event arrives
  → Actor.handle_info matches expectation trigger
  → Check debounce/cooldown → check concurrency (active < max?)
    → yes: create Episode row, start EpisodeTask under DynamicSupervisor
    → no:  apply overflow policy (queue / drop / shed_oldest)

EpisodeTask starts
  → Resolve strategy from registry
  → strategy.init(episode, trigger)
  → EpisodeRunner.execute_loop:

    ┌─────────────────────────────────────────────┐
    │  check_budget → increment_turn              │
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
    1. Persist findings (raise/update/clear) → Bus events per finding
    2. Route outputs through adapters → dedup by dedupe_key, deliver
    3. Compute final episode status from delivery outcomes
    4. Journal completion/failure step
    5. Project log via LogProjector
    6. Broadcast episode.completed/failed on Bus
    7. Emit telemetry
```

## Core concepts

### Actors

An **actor** is a GenServer that owns one or more **expectations**. Each actor watches a domain (e.g., `:procurement`, `:client_health`) and fires **episodes** when triggers match.

```elixir
defmodule MyApp.Actors.ClientHealthActor do
  use Cyclium.Actor

  actor do
    domain :client_health
    max_concurrent_episodes 5
    episode_overflow :queue

    expectation :client_should_be_healthy,
      trigger: {:event, "client.updated"},
      budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}

    expectation :contract_review,
      trigger: {:schedule, :timer.hours(24)},
      budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}
  end
end
```

**Trigger types:**
- `{:event, "event.name"}` — fires when a matching Bus event arrives
- `{:schedule, interval_ms}` — fires on a recurring timer
- `:drift` — fires when a signature changes (polling-based)
- `:manual` — fires on explicit request
- `:workflow` — fires as part of a multi-actor workflow

**Backpressure options** (`episode_overflow`):
- `:queue` — buffer excess episodes (default)
- `:drop` — discard when at capacity
- `:shed_oldest` — cancel the oldest queued episode to make room

**Expectation options:**

| Option | Default | Description |
|---|---|---|
| `trigger` | required | What fires the episode |
| `filter` | `%{}` | Payload predicates — only fire when all match |
| `debounce_ms` | `nil` | Coalesce rapid events into one firing |
| `cooldown_ms` | `nil` | Minimum gap between firings |
| `subject_key` | `nil` | Payload key to scope debounce/cooldown per subject (e.g., `:client_id`) |
| `budget` | `%{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}` | Resource limits |
| `log_strategy` | `:timeline` | Controls materialized log verbosity AND step journal detail (see below) |
| `outputs` | `[]` | Declared output types (informational) |
| `resources` | `[]` | Declared capability dependencies (informational) |
| `audit_level` | `:standard` | Audit verbosity |
| `retention_days` | `90` | How long to keep episode data. Set higher for audit-sensitive workflows (e.g., 365). Retention is declarative — enforcement requires a scheduled cleanup job (not yet built) |

**Actor ID convention:** Actor IDs are **atoms in-process** and **strings in the database**. The ID is derived from the module name: `MyApp.Actors.ClientHealthActor` becomes `:client_health_actor` in the GenServer state and `"client_health_actor"` when stored in episode rows, findings, and strategy registry lookups. The boundary is at episode creation — `Cyclium.Actor.Server` calls `to_string(state.actor_id)` when building the episode params. Everything upstream is atoms, everything downstream (DB, strategies, findings) is strings.

### Strategies

A **strategy** implements the investigation logic for an expectation. It's the brain of an episode — a stateless module that receives state and returns actions.

```elixir
defmodule MyApp.Strategies.ClientHealth do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, trigger) do
    client_id = trigger.payload["client_id"]
    {:ok, %{client_id: client_id}}
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
    client = MyApp.Clients.get!(state.client_id)
    {class, severity, summary} = classify(client)

    {:ok, %Cyclium.ConvergeResult{
      classification: %{"primary" => class, "severity" => to_string(severity)},
      confidence: 1.0,
      summary: summary,
      findings: [
        {:raise, %{
          actor_id: "client_health_actor",
          finding_key: "client:health:#{client.id}",
          class: class,
          severity: severity,
          confidence: 1.0,
          subject: %{kind: "client", id: client.id},
          subject_kind: "client",
          subject_id: client.id,
          summary: summary,
          evidence_refs: %{"active_users" => client.active_users}
        }}
      ],
      outputs: []
    }}
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
| `{:observe, data}` | Journal `data` as an observation step, then pass `{:ok, data}` to `handle_result`. This is a synchronous in-process action — no external system is called. Use it to feed data you've already gathered into the strategy's result-handling flow |
| `{:synthesize, prompt_ctx}` | Request LLM synthesis via app-provided `Cyclium.Synthesizer`. The synthesizer calls the LLM, and the response flows to `handle_result` |
| `{:checkpoint, phase_name}` | Save strategy state for crash recovery |
| `{:output, type, payload}` | Propose an output inline (outside converge) |
| `{:approval, request}` | Block episode until human approval |
| `{:wait, external_ref}` | Block episode until external event resolves |

### Multi-turn strategies

Strategies can run multiple turns before converging. `next_step` decides actions, `handle_result` absorbs outcomes — expensive work like LLM calls should be delegated to actions (`:synthesize`, `:tool_call`), not done inside `handle_result`.

This example runs three turns: observe client data → synthesize an LLM summary → converge with findings.

```elixir
defmodule MyApp.Strategies.ClientAdvisor do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @system_prompt "You are a customer success analyst. Assess the client's health."

  @impl true
  def init(_episode, trigger) do
    {:ok, %{client_id: trigger.payload["client_id"], client_data: nil, ai_summary: nil}}
  end

  @impl true
  def next_step(state, _episode_ctx) do
    cond do
      # Turn 3: we have the LLM summary, converge
      state.ai_summary ->
        :converge

      # Turn 2: we have client data, request LLM synthesis
      state.client_data ->
        {:synthesize, %{
          system: @system_prompt,
          user: "Client: #{state.client_data.name}, MRR: $#{state.client_data.mrr}, " <>
                "Status: #{state.client_data.status}"
        }}

      # Turn 1: gather client data via observation
      true ->
        client = MyApp.Clients.get!(state.client_id)
        {:observe, %{name: client.name, status: client.status, mrr: client.mrr}}
    end
  end

  @impl true
  def handle_result(state, %{kind: :observation}, {:ok, data}) do
    # Observation delivered — store the data for the next turn
    {:ok, %{state | client_data: data}}
  end

  def handle_result(state, %{kind: :synthesis}, {:ok, %{text: text}}) do
    # LLM response received — store summary
    {:ok, %{state | ai_summary: text}}
  end

  def handle_result(state, %{kind: :synthesis}, {:error, :rate_limited}) do
    # Transient failure — retry the same step
    {:retry, state}
  end

  def handle_result(_state, _step, {:error, reason}) do
    # Unrecoverable failure — abort the episode
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
          actor_id: "client_advisor_actor",
          finding_key: "client:advisor:#{state.client_id}",
          class: "ai_summary",
          severity: :low,
          confidence: 0.9,
          subject_kind: "client",
          subject_id: state.client_id,
          summary: state.ai_summary
        }}
      ],
      outputs: []
    }}
  end
end
```

**Key points:**
- `next_step` is pure decision-making — it returns what action to take, never does expensive work itself
- `handle_result` absorbs outcomes — it pattern-matches on step kind and result, then updates state
- `{:retry, state}` re-enters the loop with the same state, letting `next_step` retry the action
- `{:abort, reason}` immediately fails the episode with the given reason
- The `:synthesize` action delegates LLM calls to the app-provided `Cyclium.Synthesizer`, keeping the strategy free of HTTP concerns

### Episodes

An **episode** is one execution of a strategy. It tracks:

- Budget usage (turns, tokens, wall time)
- Step journal (every action recorded as an `EpisodeStep`)
- Classification and summary (set during converge)
- Status lifecycle: `:running` → `:done` | `:failed` | `:blocked` | `:canceled` | `:partially_failed`

Episodes run as Tasks under a DynamicSupervisor — no Oban required. The `cyclium_episodes` table serves as a durable work queue.

**Querying episodes:**

```elixir
Cyclium.Episodes.get!(episode_id)
Cyclium.Episodes.list_by_status([:running, :done, :failed])
Cyclium.Episodes.list_steps(episode_id)   # step journal
Cyclium.Episodes.get_log(episode_id)      # materialized log
Cyclium.Episodes.cancel(episode_id)       # cancellation sequence
```

### Findings

A **finding** is a persistent observation about an entity. Findings have a lifecycle:

- **Raise** — create or update an active finding (upsert by `finding_key`)
- **Update** — modify mutable fields on an active finding
- **Clear** — mark a finding as resolved (idempotent)

```elixir
# In your converge/2 callback:
findings: [
  {:raise, %{
    actor_id: "client_health_actor",
    finding_key: "client:health:123",
    class: "churned",
    severity: :high,          # :low | :medium | :high | :critical
    confidence: 1.0,
    subject: %{kind: "client", id: "123"},
    subject_kind: "client",   # denormalized for SQL Server compat
    subject_id: "123",
    summary: "Client has churned",
    evidence_refs: %{"status" => "churned"}
  }},
  {:update, "client:health:123", %{confidence: 0.8}},
  {:clear, "client:health:123"},
  {:clear, "client:health:123", "customer reactivated"}
]
```

**Finding key scoping — deduplicated vs. distinct:**

The `finding_key` controls deduplication. An active finding with the same key is updated in place (last-writer-wins on mutable fields). Choose your key strategy based on intent:

- **Deduplicated (default pattern):** Use a stable key like `"client:health:123"`. Repeated episodes update the same active finding — ideal for ongoing status tracking where you want one finding per subject.
- **Distinct per episode:** Include the episode ID in the key, e.g. `"po_review:PO-1955:#{episode.id}"`. Each episode creates a separate finding — useful for audit trails or point-in-time snapshots where every run should produce its own record.

The `episode_ctx` map passed to `converge/2` contains `episode_id`, so you can reference it directly:

```elixir
# Deduplicated: one active finding per client, updated each run
def converge(state, _episode_ctx) do
  {:ok, %Cyclium.ConvergeResult{
    findings: [{:raise, %{finding_key: "client:health:#{state.client_id}", ...}}]
  }}
end

# Distinct: one finding per episode run
def converge(state, episode_ctx) do
  {:ok, %Cyclium.ConvergeResult{
    findings: [{:raise, %{finding_key: "po_review:#{state.po_id}:#{episode_ctx.episode_id}", ...}}]
  }}
end
```

Findings are queried via `Cyclium.Findings.active_for/1`:

```elixir
Cyclium.Findings.active_for(actor: "client_health_actor")
Cyclium.Findings.active_for(subject: %{kind: "client", id: "123"})
Cyclium.Findings.active_for(finding_key: "client:health:123")
Cyclium.Findings.active_for(class: "churned")
```

### Outputs

Outputs are typed proposals produced during converge. They flow through the **Output Router**, which handles deduplication (via `dedupe_key`) and delivery through app-provided adapters.

```elixir
# In converge result:
outputs: [
  %Cyclium.OutputProposal{
    type: :email,
    dedupe_key: "alert:client:123:#{Cyclium.Window.bucket(:h4, DateTime.utc_now())}",
    payload: %{to: "team@co.com", subject: "Client 123 churned"},
    requires_approval: false
  }
]
```

Register adapters in config:

```elixir
config :cyclium, :output_adapters, %{
  email: MyApp.Adapters.Email,
  slack: MyApp.Adapters.Slack
}
```

Adapters implement `Cyclium.Output.Adapter`:

```elixir
defmodule MyApp.Adapters.Email do
  @behaviour Cyclium.Output.Adapter

  @impl true
  def deliver(:email, payload, _ctx) do
    case MyApp.Mailer.send(payload) do
      :ok -> {:ok, %{message_id: "abc123"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Bus

The event bus connects actors, LiveViews, and workflows without coupling. It wraps Phoenix.PubSub.

```elixir
# Publish a domain event (from your app code):
Cyclium.Bus.broadcast("client.updated", %{client_id: "123"})

# Subscribe to all events (actors do this automatically):
Cyclium.Bus.subscribe()

# Subscribe to a specific event:
Cyclium.Bus.subscribe("episode.completed")

# In a LiveView or GenServer:
def handle_info({:bus, "episode.completed", payload}, socket) do
  # payload contains: episode_id, actor_id, status, workflow_instance_id
end
```

**Runtime events emitted by Cyclium:**

| Category | Events |
|---|---|
| Episode lifecycle | `episode.completed`, `episode.failed`, `episode.canceled`, `episode.queued`, `episode.dropped` |
| Expectations | `expectation.triggered` |
| Findings | `finding.raised`, `finding.updated`, `finding.cleared` |
| Outputs | `output.delivered` |
| Workflows | `workflow.started`, `workflow.completed`, `workflow.failed` |
| System | `spec.updated` |

## Setup

### 1. Add dependency

```elixir
# mix.exs
def deps do
  [{:cyclium, path: "../cyclium_ex"}]
end
```

Dependencies pulled in: `ecto`, `ecto_sql`, `jason`, `phoenix_pubsub`.

### 2. Run migrations

```elixir
# In a migration file:
def up do
  Cyclium.Migrations.V1.up()   # episodes, steps, checkpoints, findings, outputs
  Cyclium.Migrations.V2.up()   # episode_logs
  Cyclium.Migrations.V3.up()   # workflow_instances
  Cyclium.Migrations.V4.up()   # archived_at on episodes and findings
end

def down do
  Cyclium.Migrations.V4.down()
  Cyclium.Migrations.V3.down()
  Cyclium.Migrations.V2.down()
  Cyclium.Migrations.V1.down()
end
```

### 3. Configure

```elixir
# config.exs
config :cyclium, :repo, MyApp.Repo
config :cyclium, :strategy_registry, MyApp.StrategyRegistry

# Optional: episode runner (default: Cyclium.Runner.OTP)
config :cyclium, :runner, Cyclium.Runner.OTP

# Optional: tool capabilities
config :cyclium, :capability_registry, %{
  erp_read: MyApp.Tools.ERP,
  vendor_api: MyApp.Tools.VendorAPI
}

# Optional: output adapters
config :cyclium, :output_adapters, %{
  email: MyApp.Adapters.Email,
  slack: MyApp.Adapters.Slack
}

# Optional: checkpoint schemas for versioned state migration
config :cyclium, :checkpoint_schemas, %{
  {"client_health_actor", "client_should_be_healthy"} => MyApp.Checkpoints.HealthCheck
}

# Optional: enable reconciler for hot spec changes
config :cyclium, :reconciler, true

# Optional: register workflows
config :cyclium, :workflows, [MyApp.Workflows.ClientReview]
```

### 4. Strategy registry

Map actor/expectation pairs to strategy modules:

```elixir
defmodule MyApp.StrategyRegistry do
  def strategy_for("client_health_actor", _), do: MyApp.Strategies.ClientHealth
  def strategy_for("client_advisor_actor", _), do: MyApp.Strategies.ClientAdvisor
  def strategy_for(actor, exp), do: raise "No strategy for #{actor}/#{exp}"
end
```

### 5. Supervision tree

```elixir
# application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Cyclium.Supervisor, pubsub: MyApp.PubSub},
  MyApp.Actors.ClientHealthActor,
  MyApp.Actors.ClientAdvisorActor,
  MyAppWeb.Endpoint
]
```

`Cyclium.Supervisor` starts the DynamicSupervisors, TaskSupervisor, and optionally the Reconciler and WorkflowEngine.

## Budgets

Every expectation declares a budget. The runner enforces all three dimensions:

```elixir
budget: %{
  max_turns: 12,        # loop iterations (incremented every next_step call)
  max_tokens: 25_000,   # LLM token cost (incremented by tool_call results)
  max_wall_ms: 120_000  # wall-clock deadline (enforced via Process.send_after)
}
```

When any limit is hit, the episode fails with `error_class: "budget_exceeded"`. Wall time is enforced asynchronously — a `:budget_wall_exceeded` message interrupts the loop even if the strategy is blocked on a tool call.

## Deduplication: actor-level vs. strategy-level

Cyclium provides three layers of temporal dedup:

**Actor-level global (`cooldown_ms`)** — enforced by the actor GenServer before an episode starts. Simple and zero-cost, but applies globally to the expectation — *all* subjects are blocked during the window.

```elixir
expectation :client_ai_summary,
  trigger: {:event, "client.summary_requested"},
  cooldown_ms: :timer.minutes(5)  # no advisor episodes for ANY client for 5 min
```

**Actor-level per-subject (`subject_key` + `debounce_ms`/`cooldown_ms`)** — when `subject_key` is set, debounce and cooldown are scoped per subject value. Each unique subject gets its own independent trailing-edge timer and cooldown window. Client A and client B are debounced independently.

```elixir
expectation :client_ai_summary,
  trigger: {:event, "client.summary_requested"},
  subject_key: :client_id,
  debounce_ms: :timer.seconds(10),   # trailing-edge, per-client
  cooldown_ms: :timer.minutes(5)     # minimum gap, per-client
```

When `subject_key` is set but the payload doesn't contain that key, the subject value is `nil` and the key becomes `{expectation_id, nil}` — still isolated from real subjects, never crashing.

**Strategy-level (`Findings.recent?/2`)** — checked in `init/2` using the existing finding for a specific subject. This is DB-backed, so it survives actor restarts unlike the in-memory actor-level dedup.

```elixir
@summary_cooldown_ms :timer.minutes(5)

def init(_episode, trigger) do
  client_id = trigger.payload["client_id"]
  skip = Cyclium.Findings.recent?("client:advisor:#{client_id}", @summary_cooldown_ms)
  {:ok, %{client_id: client_id, skip: skip}}
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

## Workflows

Workflows coordinate multiple actors in a dependency graph. Data flows between steps via the `workflow_result/2` strategy callback and `input:` functions on downstream steps.

### Defining a workflow

```elixir
defmodule MyApp.Workflows.ClientReview do
  use Cyclium.Workflow

  workflow do
    trigger {:event, "client.review_requested"}

    step :health_check,
      actor: :client_health_actor,
      expectation: :client_should_be_healthy

    step :ai_summary,
      actor: :client_advisor_actor,
      expectation: :client_ai_summary,
      depends_on: [:health_check],
      input: fn _trigger, prior ->
        # prior[:health_check] contains the map returned by
        # the health strategy's workflow_result/2 callback
        %{client_id: prior[:health_check].client_id}
      end

    on_failure :health_check, policy: :retry, max_step_attempts: 3, backoff_ms: 5_000
    on_failure :ai_summary, policy: :abort
  end
end
```

### Passing data between steps

When a workflow step completes, the engine calls the strategy's optional `workflow_result/2` callback to extract the data that downstream steps receive via `prior`. If `workflow_result/2` is not implemented, downstream steps receive `nil` for that step's prior.

```elixir
defmodule MyApp.Strategies.ClientHealth do
  @behaviour Cyclium.EpisodeRunner.Strategy

  # ... init, next_step, handle_result, converge as usual ...

  # Optional: extract data for downstream workflow steps
  @impl true
  def workflow_result(state, _converge_result) do
    # This map becomes prior[:health_check] in downstream input functions
    %{client_id: state.client_id, classification: state.classification}
  end
end
```

### Configuration and usage

Register workflows in config:

```elixir
config :cyclium, :workflows, [MyApp.Workflows.ClientReview]
```

The `WorkflowEngine` GenServer:
- Listens for trigger events on the Bus
- Creates a `WorkflowInstance` record to track execution
- Fires steps in dependency order (DAG validated at compile time)
- Passes data between steps via `workflow_result/2` → `input` functions
- Applies failure policies per-step: `:abort` (cancel all), `:retry` (with backoff), `:pause` (wait for manual intervention)

Workflows can also be started manually:

```elixir
Cyclium.WorkflowEngine.start_workflow(
  MyApp.Workflows.ClientReview,
  %{client_id: "123"},
  []
)
```

## Logging and observability

### Log strategies

Set per-expectation via `log_strategy`. Controls both the materialized log (LogProjector) and what gets stored in step journal columns (`args_redacted`, `result_ref`):

| Strategy | Step journal `args_redacted` | Step journal `result_ref` | Materialized log |
|---|---|---|---|
| `:none` | omitted | omitted | none |
| `:summary_only` | omitted | omitted | one-line status summary |
| `:timeline` | tool name + action only | summary/IDs only | step-by-step with timestamps |
| `:full_debug` | full prompt_ctx / tool args | full result payload | timeline + args, results, errors |

Use `:full_debug` for audit-sensitive workflows where you need to reconstruct exactly what context an LLM had (EOX predictions, SKU classifications). Use `:timeline` for high-frequency episodes where you want the flow visible without storing full payloads.

Tool implementations also control what gets journaled via two callbacks that run **before** log_strategy filtering: `redact/1` strips bulky data from args, and `redact_result/1` strips bulky data from results. This gives tools domain-specific control over what's stored, independent of the episode's log_strategy.

Materialized logs are stored in `cyclium_episode_logs` by `Cyclium.LogProjector` and can be queried via `Cyclium.Episodes.get_log(episode_id)`.

### Telemetry

Cyclium emits 28 structured telemetry events under the `[:cyclium, ...]` prefix. Attach a handler for development:

```elixir
Cyclium.Telemetry.attach_default_logger()
```

Key events:

| Event | Metadata |
|---|---|
| `[:cyclium, :episode, :completed]` | episode_id, actor_id, output_count, finding_count |
| `[:cyclium, :episode, :failed]` | episode_id, actor_id |
| `[:cyclium, :step, :tool_call]` | tool, action, episode_id |
| `[:cyclium, :step, :synthesis]` | episode_id |
| `[:cyclium, :finding, :raised]` | finding_key, actor_id, class |
| `[:cyclium, :finding, :cleared]` | finding_key, actor_id, class |
| `[:cyclium, :output, :delivered]` | type, episode_id |
| `[:cyclium, :actor, :event_received]` | actor_id, event_type |
| `[:cyclium, :actor, :overflow]` | actor_id, policy |

Full list: `Cyclium.Telemetry.events/0`

### Step journal

Every episode action is recorded as an `EpisodeStep` with one of 16 kinds:

`tool_call`, `synthesis`, `observation`, `checkpoint`, `output_proposed`, `output_delivered`, `output_failed`, `approval_requested`, `approval_resolved`, `wait_started`, `wait_resolved`, `finding_raised`, `finding_updated`, `finding_cleared`, `episode_completed`, `episode_failed`

Each step records: `step_no`, `kind`, `tool_name`, `args_redacted`, `result_ref`, `error_class`, `error_detail`, `cost_tokens`, `cost_ms`, `created_at`.

Query steps: `Cyclium.Episodes.list_steps(episode_id)`

## Checkpointing

Strategies can save state mid-episode for crash recovery:

```elixir
def next_step(state, _ctx) do
  if state.phase == :data_collected do
    {:checkpoint, "data_collected"}
  else
    {:tool_call, :erp_read, :read_po, %{"po_id" => state.po_id}}
  end
end
```

On crash/restart, `EpisodeTask` loads the latest checkpoint and calls the strategy's checkpoint schema to migrate state forward if needed:

```elixir
defmodule MyApp.Checkpoints.HealthCheck do
  use Cyclium.CheckpointSchema, version: 2

  # Migrate from version 1 → 2
  def migrate(1, state), do: {:ok, Map.put(state, :new_field, nil)}
end
```

Register in config:

```elixir
config :cyclium, :checkpoint_schemas, %{
  {"client_health_actor", "client_should_be_healthy"} => MyApp.Checkpoints.HealthCheck
}
```

## Tools

External capabilities are registered as tools implementing `Cyclium.Tool`. Use `use Cyclium.Tool` for sensible defaults — the only required callback is `call/3`:

```elixir
defmodule MyApp.Tools.ERP do
  use Cyclium.Tool

  @impl true
  def call(:read_po, args, _ctx) do
    case MyApp.ERP.get_po(args["po_id"]) do
      {:ok, po} -> {:ok, po}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Override optional callbacks as needed:

```elixir
defmodule MyApp.Tools.VendorAPI do
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

  # Cache key scope — same PO ID returns cached result
  @impl true
  def cache_scope(args), do: args["po_id"]
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
  erp_read: MyApp.Tools.ERP,
  vendor_api: MyApp.Tools.VendorAPI
}
```

Strategies invoke tools via `{:tool_call, :erp_read, :read_po, %{"po_id" => "PO-123"}}`. The `ToolExec` wrapper handles capability resolution, caching, redaction, and error classification.

## Reconciler

The optional `Cyclium.Reconciler` watches for `spec.updated` Bus events and reconciles running actors when their configuration changes at runtime:

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

## LiveView integration

Cyclium integrates with Phoenix LiveView via the Bus. Subscribe in your LiveView's mount and handle events:

```elixir
defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket), do: Cyclium.Bus.subscribe()
    {:ok, assign(socket, findings: load_findings())}
  end

  def handle_info({:bus, event, _payload}, socket)
      when event in ["finding.raised", "finding.updated", "finding.cleared"] do
    {:noreply, assign(socket, findings: load_findings())}
  end

  def handle_info({:bus, _event, _payload}, socket) do
    {:noreply, socket}
  end
end
```

## Database tables

All tables use `binary_id` primary keys and are SQL Server 2017 compatible (no JSON operators in DDL, application-layer upserts, denormalized columns for indexed queries).

| Table | Migration | Purpose |
|---|---|---|
| `cyclium_episodes` | V1 | Episode lifecycle, budget tracking, classification |
| `cyclium_episode_steps` | V1 | Step-by-step journal (16 step kinds) |
| `cyclium_episode_checkpoints` | V1 | Versioned strategy state snapshots |
| `cyclium_findings` | V1 | Persistent observations with raise/update/clear lifecycle |
| `cyclium_outputs` | V1 | Output proposals, delivery status, deduplication |
| `cyclium_episode_logs` | V2 | Materialized human-readable logs |
| `cyclium_workflow_instances` | V3 | Workflow execution tracking and step states |

## Window helpers

`Cyclium.Window` provides clock-aligned deduplication buckets for output `dedupe_key` construction:

```elixir
Cyclium.Window.bucket(:h4, DateTime.utc_now())   # "2026-02-24T08"  (4-hour windows)
Cyclium.Window.bucket(:h24, DateTime.utc_now())   # "2026-02-24"     (daily)
Cyclium.Window.bucket(:h48, DateTime.utc_now())   # "2026-02-24"     (every-other-day)
Cyclium.Window.bucket(:w1, DateTime.utc_now())    # "2026-W09"       (ISO week)
```

Use these in `dedupe_key` to prevent duplicate outputs within a time window:

```elixir
dedupe_key: "alert:client:#{id}:#{Cyclium.Window.bucket(:h4, DateTime.utc_now())}"
```

## Batch helpers

`Cyclium.Batch` provides a lightweight struct for strategies that process data in grouped batches across multiple `:synthesize` calls. No new step types — strategies continue using `:tool_call` and `:synthesize` as normal.

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

Progress tracking via `Batch.group_count/1`, `Batch.processed_count/1`, and `Batch.done?/1`.

## Per-item episodes vs. batch processing

Batch helpers are useful when a single episode needs to process many items in groups — but they're not the only pattern. An alternative is to **fire one episode per item**, driven by domain events. This is the pattern used by the project health actor.

**The difference:**

| Approach | When to use | Episode count |
|---|---|---|
| Batch (single episode) | Scheduled sweep over a large dataset; items need cross-comparison | One episode, many `:synthesize` turns |
| Per-item (many episodes) | Event-driven re-evaluation; each item is independent | One episode per item |

**Per-item pattern — ProjectHealthActor:**

The actor listens for `"project.updated"` events. Each event carries a `project_id`, and each project gets its own independent episode. There's no need to load the full dataset — the trigger tells you which item changed.

```elixir
defmodule MyApp.Actors.ProjectHealthActor do
  use Cyclium.Actor

  actor do
    domain :project_health
    max_concurrent_episodes 5
    episode_overflow :queue

    expectation :project_should_be_healthy,
      trigger: {:event, "project.updated"},
      subject_key: :project_id,
      debounce_ms: :timer.seconds(2),
      budget: %{max_turns: 3, max_tokens: 1_000, max_wall_ms: 10_000}
  end
end
```

The strategy is single-turn — load the item, classify it deterministically, emit findings:

```elixir
defmodule MyApp.Strategies.ProjectHealth do
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, trigger) do
    {:ok, %{project_id: trigger.payload["project_id"]}}
  end

  @impl true
  def next_step(_state, _episode_ctx), do: :converge

  @impl true
  def handle_result(state, _step, _result), do: {:ok, state}

  @impl true
  def converge(state, episode_ctx) do
    project = MyApp.Projects.get!(state.project_id)
    percent_spent = project.spent / max(project.budget, 1)
    days_remaining = Date.diff(project.due_date, Date.utc_today())

    {class, severity, summary} = classify(project.status, percent_spent, days_remaining)

    {:ok, %Cyclium.ConvergeResult{
      classification: %{"primary" => class, "severity" => to_string(severity)},
      confidence: 1.0,
      summary: summary,
      findings: [
        {:raise, %{
          actor_id: "project_health_actor",
          finding_key: "project:health:#{project.id}:#{episode_ctx.episode_id}",
          class: class,
          severity: severity,
          confidence: 1.0,
          subject_kind: "project",
          subject_id: project.id,
          summary: summary,
          evidence_refs: %{
            "percent_spent" => percent_spent,
            "days_remaining" => days_remaining
          }
        }}
      ],
      outputs: []
    }}
  end

  defp classify(:completed, _pct, _days), do: {"complete", :low, "Project completed"}
  defp classify(_s, pct, _d) when pct > 1.0, do: {"over_budget", :high, "Over budget"}
  defp classify(_s, pct, _d) when pct > 0.85, do: {"budget_risk", :medium, "Budget at risk"}
  defp classify(_s, _pct, d) when d < 0, do: {"overdue", :high, "Past due date"}
  defp classify(_s, _pct, d) when d < 3, do: {"schedule_risk", :medium, "Due date approaching"}
  defp classify(_s, _pct, _d), do: {"healthy", :low, "On track"}
end
```

**Why this works well:**

- **Reactive** — evaluation happens the moment data changes, not on a polling schedule
- **Isolated** — each project gets its own episode with its own budget, journal, and findings
- **Backpressure built in** — `max_concurrent_episodes` + `debounce_ms` + `subject_key` prevent a burst of updates from overwhelming the system. Rapid updates to the same project coalesce into one episode
- **Findings create an audit trail** — the episode-scoped `finding_key` (`"project:health:#{id}:#{episode_id}"`) means each evaluation produces its own finding, giving you a point-in-time history of how health evolved

**When to reach for Batch instead:** If you need to process 500 items in one pass (e.g., a nightly SKU classification sweep), a single episode with `Cyclium.Batch` is more efficient than 500 separate episodes — fewer rows, one journal, and the ability to compare items within groups.

## Synthesizers

A **synthesizer** is the bridge between strategies and LLM infrastructure. It implements `Cyclium.Synthesizer` and is called when a strategy returns `{:synthesize, prompt_ctx}`. The synthesizer handles the actual LLM call, and its response flows back through `handle_result/3`.

```elixir
defmodule MyApp.Synthesizers.ProjectAnalysis do
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

**Actor-level** — inherited by all expectations in the actor:

```elixir
defmodule MyApp.Actors.ProjectAdvisorActor do
  use Cyclium.Actor

  actor do
    domain :project_advisory
    synthesizer MyApp.Synthesizers.ProjectAnalysis

    max_concurrent_episodes 3
    episode_overflow :queue

    expectation :project_ai_summary,
      trigger: {:event, "project.summary_requested"},
      budget: %{max_turns: 5, max_tokens: 10_000, max_wall_ms: 30_000}

    expectation :project_risk_assessment,
      trigger: {:event, "project.risk_review_requested"},
      budget: %{max_turns: 8, max_tokens: 15_000, max_wall_ms: 60_000}
  end
end
```

Both expectations above use `MyApp.Synthesizers.ProjectAnalysis`.

**Expectation-level** — overrides the actor-level synthesizer for a specific expectation:

```elixir
actor do
  domain :project_advisory
  synthesizer MyApp.Synthesizers.ProjectAnalysis   # default for this actor

  expectation :project_ai_summary,
    trigger: {:event, "project.summary_requested"},
    synthesizer: MyApp.Synthesizers.FastSummary     # override for this expectation

  expectation :project_risk_assessment,
    trigger: {:event, "project.risk_review_requested"}
    # uses ProjectAnalysis (inherited from actor)
end
```

The strategy itself doesn't know or care which synthesizer is wired in — it just returns `{:synthesize, prompt_ctx}` and receives the result in `handle_result`:

```elixir
def next_step(%{project_data: data, ai_summary: nil}, _ctx) do
  {:synthesize, %{
    system: "You are a project risk analyst.",
    user: "Project: #{data.name}, #{data.percent_spent * 100}% spent, #{data.days_remaining} days left"
  }}
end

def handle_result(state, %{kind: :synthesis}, {:ok, %{text: text}}) do
  {:ok, %{state | ai_summary: text}}
end
```

**When you don't need a synthesizer:** If your strategy is purely deterministic (like the ProjectHealthStrategy above), you don't need to declare a synthesizer at all. The synthesizer is only invoked when a strategy returns `{:synthesize, prompt_ctx}` — if your strategy never does, the synthesizer configuration is ignored.

### LLM-provided confidence

Findings have a `confidence` field (0.0–1.0). For deterministic strategies, hardcoding `1.0` is fine. But when an LLM produces the assessment, you can ask it to self-report confidence and pass that through to the finding.

**Step 1 — Add `confidence` to the tool schema in your synthesizer:**

```elixir
@tool_definition %{
  type: "function",
  function: %{
    name: "project_health_assessment",
    parameters: %{
      type: "object",
      properties: %{
        class: %{type: "string", enum: ["healthy", "at_risk", "critical"]},
        severity: %{type: "string", enum: ["low", "medium", "high", "critical"]},
        summary: %{type: "string", description: "One sentence health summary"},
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

The description matters — it tells the LLM what the scale means, which produces more calibrated values than a bare `"confidence"` field.

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
        finding_key: "project:health:#{state.project_id}:#{episode_ctx.episode_id}",
        confidence: confidence,
        # ... other finding fields
      }}
    ]
  }}
end

defp parse_confidence(val) when is_number(val), do: max(0.0, min(val, 1.0))
defp parse_confidence(_), do: 0.5
```

The `parse_confidence/1` helper clamps to `[0.0, 1.0]` and falls back to `0.5` if the LLM returns something unexpected. The same confidence flows into both the `ConvergeResult` (episode-level) and the finding (queryable).

**When to hardcode instead:** If the classification is deterministic (rule-based, no LLM), use `confidence: 1.0`. The LLM confidence pattern is for cases where the assessment involves judgment — ambiguous data, sparse evidence, or nuanced classification where the LLM's certainty is genuinely informative.

## Demo application

See [cyclium_ex_hapi](../cyclium_ex_hapi) for a complete Phoenix LiveView application demonstrating Cyclium:

- Client health monitoring with real-time evaluation
- LLM-powered AI advisor actor (Anthropic Claude integration)
- Simulation controls for testing different scenarios
- Episode detail view with step timeline and rendered logs
- Reactive UI via Bus event subscriptions

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

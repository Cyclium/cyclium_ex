# Distributed Operations

How Cyclium runs long-lived, recoverable work across a cluster of application
nodes — without Oban, Redis, or leader election. Covers crash recovery, the
lease-based work-claim layer, node identity, multi-stack partitioning, and
trigger-only (deferred execution) mode.

> Examples use a generic **resource** domain (`resource_monitor` /
> `resource_advisor` actors).

## Recovery

Cyclium provides built-in recovery for orphaned episodes after server restarts or
deploys.

### The problem

When a node shuts down (deploy, crash, scaling event), in-flight episodes are
killed and left as `:running` in the database. Without recovery, these episodes
stay orphaned forever.

### Distributed episode claiming

In a multi-node cluster, all nodes run the same actors and receive the same Bus
events via PG2. Without coordination, every node would independently create and
run an episode for every trigger — tripling (or more) the work. Cyclium uses
DB-based coordination with no Redis or leader election required.

#### Episode creation: dedupe_key

When a trigger fires, every node's actor calls `maybe_fire_episode`. Before
inserting, the actor generates a deterministic `dedupe_key`:

- **Schedule triggers:** `"schedule:{actor_id}:{expectation_id}:{date}"` — one
  episode per schedule window
- **Event triggers:** `"event:{actor_id}:{expectation_id}:{payload_hash}"` — one
  episode per distinct event payload

A filtered unique index on `dedupe_key`
(`WHERE dedupe_key IS NOT NULL AND archived_at IS NULL`) ensures only one node's
insert succeeds. The other nodes receive a constraint violation and silently skip
— no episode created, no work duplicated. Archived episodes are excluded from the
constraint so that re-triggered work isn't blocked by old runs.

A random jitter (0-200ms) before insert spreads winners evenly across nodes,
preventing one faster node from consistently claiming all episodes:

```elixir
# In Actor.Server.maybe_fire_episode/3
Process.sleep(:rand.uniform(200))
enqueue_episode(state, episode_params)
```

The constraint violation is caught in `enqueue_episode` using the same pattern as
the Output router:

```elixir
{:error, %Ecto.Changeset{} = cs} ->
  if has_dedupe_violation?(cs) do
    Logger.debug("[#{state.actor_id}] Dedupe skip: #{params.dedupe_key}")
  end
  state
```

#### Recovery claims: optimistic update

After a restart, all surviving nodes run `Cyclium.Recovery.sweep/1`. Each node
sees the same list of stale episodes, but only one node can claim each episode:

```elixir
# Episodes.claim_for_recovery/1
from(e in Episode,
  where: e.id == ^episode_id and e.status == :running and is_nil(e.archived_at)
)
|> repo().update_all(set: [phase: "recovering"])
```

This is an atomic `UPDATE ... WHERE` — the first node to execute it sets
`phase: "recovering"` and gets `{1, _}` back. All other nodes get `{0, _}` (no
rows affected) and skip. No locks, no races, no distributed coordination protocol
needed.

#### Summary of coordination guarantees

| Scenario | Mechanism | Guarantee |
|----------|-----------|-----------|
| Same trigger on N nodes | `dedupe_key` unique index | Exactly one episode created |
| Same orphan on N nodes | Optimistic `UPDATE ... WHERE` | Exactly one node recovers it |
| Archived episodes | Filtered unique index excludes `archived_at IS NOT NULL` | Re-triggering is not blocked by old runs |
| New episode, node with lower latency | Random jitter (0-200ms) before insert | Winners distributed evenly over time |
| Recovery, node with lower latency | Per-node shuffle of the stale list | Recovered episodes spread across the cluster, not piled on one node |
| Recovered `:restart` execution | Routed through the actor's `max_concurrent_episodes` + queue | No thundering herd — recovered work runs at normal per-node capacity |

### Recovery sweep

`Cyclium.Recovery.sweep/1` finds stale `:running` episodes and recovers them:

1. Query episodes where the most recent step journal entry is older than
   `stale_after_ms` (default: 2 minutes)
2. Attempt optimistic claim on each stale episode
3. If claimed, apply the expectation's `recovery_policy`:
   - `:restart` — enqueue fresh (re-runs `strategy.init/2`)
   - `:fail` (default) — mark `:failed` with `error_class: "orphaned"`
4. Emit `[:cyclium, :recovery, :sweep]` telemetry with counts

Policy resolution checks the compiled `:actor_registry` map first, then falls
back to the `cyclium_agent_definitions` table for dynamic actors. Unknown actors
default to `:fail`.

### Avoiding recovery concentration on one node

A naive sweep can pile all recovered work onto a single node, because every node
wakes on the same timer and races to claim the same stale list. Cyclium guards
against this on two axes:

- **Claim distribution.** Each node **shuffles** its stale list before claiming.
  Without this, all nodes iterate the same (unordered) list and the node with the
  lowest DB latency wins the optimistic claim for episode #1, then #2, then the
  whole list. Shuffling decorrelates the claim order so wins spread roughly evenly
  across the cluster — the optimistic `UPDATE … WHERE` still guarantees
  exactly-once recovery.
- **Execution backpressure.** A `:restart` is handed to the actor's *live process*
  via `{:recover_episode, id}`, so it runs under the actor's
  `max_concurrent_episodes` and in-memory queue — exactly like a normal trigger.
  This prevents a node that still wins a lopsided share of claims from spawning
  every recovered episode at once (a thundering herd that bypasses backpressure).
  Recovered episodes are **always queued, never dropped or shed**, since they
  represent real in-flight work; they drain as active slots free up. If the actor
  process can't be located on the sweeping node (no compiled module in the
  `actor_registry`, or a dynamic actor that isn't running), recovery falls back to
  a direct runner enqueue.

For compiled actors, pass the `actor_registry` so recovery can address the live
process by module name; dynamic actors are addressed by their global name
automatically.

### Workflow reconciliation

`Cyclium.Recovery.reconcile_workflows/0` handles a related problem: workflow
instances stuck in `:running` because the WorkflowEngine missed a Bus event
during a restart.

The WorkflowEngine is purely event-driven — it advances workflows when it
receives `episode.completed` or `episode.failed` Bus events. If the engine wasn't
running when those events fired (e.g. during a deploy), the workflow step_states
become stale and the workflow hangs.

Reconciliation fixes this by:

1. Finding all `:running` / `:blocked` workflow instances
2. For each step marked `"running"` in step_states, loading the actual episode
3. If the episode has already reached a terminal state, re-broadcasting the
   appropriate Bus event
4. The WorkflowEngine handles the replayed event through its normal path — no
   special logic needed

Call `reconcile_workflows/0` **after** `sweep/1` and after workflow configs are
registered (compiled modules booted, dynamic workflows loaded).

### Setting recovery policy

Add `recovery_policy` to the expectation DSL:

```elixir
actor do
  expectation(:check_resource_limits,
    strategy: MyApp.Strategies.ResourceLimits,
    trigger: {:event, "resource.updated"},
    recovery_policy: :restart,
    budget: %{max_turns: 5, max_tokens: 25_000, max_wall_ms: 120_000}
  )
end
```

Use `:restart` for idempotent strategies that re-query data from the DB. Use
`:fail` (default) for strategies with non-idempotent side effects where automatic
recovery could cause harm.

### Wiring up recovery in your app

Add a delayed recovery task to your Cyclium supervisor with an `:actor_registry`
map that maps actor `identifier()` strings to their modules. Cyclium looks up the
`recovery_policy` from each actor's compiled expectations automatically. Dynamic
actors not in the registry are resolved from the DB.

```elixir
# Maps identifier (as DB string) → actor module for recovery sweep.
# Must match the identifier() declared in each actor's DSL block.
@actor_registry %{
  "resource_monitor" => MyApp.Actors.ResourceMonitor,
  "resource_advisor" => MyApp.Actors.ResourceAdvisorActor
}

children = [
  {Cyclium.Supervisor, pubsub: MyApp.PubSub},
  MyApp.Actors.ResourceMonitor,
  MyApp.Actors.ResourceAdvisorActor,
  {Task, fn ->
    # Wait for cluster to settle after deploy
    Process.sleep(:timer.minutes(2))
    Cyclium.Recovery.sweep(actor_registry: @actor_registry)
    Cyclium.Recovery.reconcile_workflows()
  end}
]
```

For custom policy logic, pass `:resolve_policy` instead:

```elixir
Cyclium.Recovery.sweep(
  resolve_policy: fn episode ->
    if episode.actor_id == "critical_actor", do: :restart, else: :fail
  end
)
```

### Deploy sequence

1. Node gets SIGTERM → 30s graceful shutdown timeout
2. Episodes trap exits, try to finish current step within remaining time
3. Episodes that don't finish stay `:running` in DB
4. After boot, each node waits 2 minutes before running recovery sweep
5. Sweep finds stale episodes via step journal recency
6. First node to claim each orphan via optimistic update handles recovery
7. Workflow reconciliation replays missed Bus events for stale workflow steps

## Work Claims (distributed lease coordination)

For clusters where multiple applications share the same database and actor
definitions, work claims provide lease-based coordination to ensure at-most-once
execution.

### How it works

1. Before executing an episode, `EpisodeTask` calls `WorkClaims.gate_acquire/3`
   with the episode's `dedupe_key`
2. If claimed successfully, a `Heartbeat` GenServer renews the lease periodically
   (every lease/3 seconds)
3. On completion, the claim is marked `:done`; on crash, `:failed`
4. If a node dies, the lease expires and another node can steal it

Work claims also coordinate trigger request dispatch —
`TriggerRequests.Poller` acquires a claim per request before dispatching to
prevent multiple full-mode nodes from processing the same deferred episode.

### Configuration

```elixir
# Use the built-in Ecto-based implementation:
config :cyclium, work_claims: Cyclium.WorkClaims.EctoClaims

# Or a SQL Server-optimized adapter in consuming apps:
config :cyclium, work_claims: MyApp.WorkClaims.SqlServer

# Lease duration (default: 120 seconds)
config :cyclium, work_claims_lease_seconds: 180

# Or omit work_claims entirely — no claiming, fully backwards compatible
```

When unconfigured, all `gate_*` functions return passthrough values with zero
overhead.

### Writing a custom adapter

Implement the `Cyclium.WorkClaims` behaviour with 5 callbacks:

```elixir
defmodule MyApp.WorkClaims.SqlServer do
  @behaviour Cyclium.WorkClaims

  @impl true
  def acquire(dedupe_key, owner_node, opts) do
    # Use hints: ["UPDLOCK"] for SQL Server lock acquisition
    # Transaction-based: read with lock, then insert or update
  end

  @impl true
  def renew(dedupe_key, owner_node, lease_seconds), do: # ...
  def complete(dedupe_key, owner_node), do: # ...
  def fail(dedupe_key, owner_node, error_detail), do: # ...
  def reclaim_expired(limit), do: # ...
end
```

The default `EctoClaims` implementation uses plain transactions (no lock hints)
and works with any Ecto adapter. For SQL Server, a custom adapter can use
`hints: ["UPDLOCK"]` on the read query inside the transaction for stronger
concurrency guarantees.

### Database table

The `cyclium_work_claims` table is created by V6 migration:

| Column | Type | Notes |
|--------|------|-------|
| `dedupe_key` | string(512) | Unique — matches the episode's dedupe_key |
| `state` | string(32) | `claimed`, `done`, `failed`, `expired` |
| `owner_node` | string(255) | Node holding the lease |
| `lease_until` | utc_datetime | When the lease expires |
| `attempt` | integer | Incremented on each steal/reclaim |

### Integration with recovery

When work claims are configured, `Recovery.sweep/1` uses `gate_acquire` to
coordinate across nodes before claiming orphaned episodes. This provides two
layers of coordination: the work claim lease prevents concurrent execution, and
the optimistic `claim_for_recovery` update prevents duplicate recovery actions.

### Lease tuning

The lease duration (`work_claims_lease_seconds`, default: 120s) controls the
trade-off between availability and the "zombie window" — the time between a node
crash and another node stealing the work.

| Setting | Zombie window | Heartbeat interval | Good for |
|---------|---------------|-------------------|----------|
| 60s | ~60s | ~20s | Short tasks, fast failover |
| 120s (default) | ~120s | ~40s | Most workloads |
| 300s | ~5min | ~100s | Long-running tasks, flaky networks |

**Guidelines:**

- Heartbeat fires at `lease / 3` — set the lease to at least 3x your worst-case
  DB round-trip time
- If your episodes typically run for minutes, 120s is fine — the heartbeat keeps
  the lease alive indefinitely
- If network partitions last >30s regularly, increase the lease to avoid false
  steals
- After a steal, the new node restarts the episode fresh (strategies should be
  idempotent)

### Heartbeat failure modes

The heartbeat GenServer is linked to the EpisodeTask process:

- **Heartbeat crashes** — The EpisodeTask traps the EXIT and can restart the
  heartbeat. The lease has margin (only 1/3 expired per interval), so a brief
  restart is safe.
- **EpisodeTask crashes** — The heartbeat dies with it. The rescue block marks
  the claim as `:failed`. If it doesn't (hard kill), the lease expires naturally
  and another node can steal it.
- **DB becomes unreachable** — Heartbeat renewal fails, lease expires. When DB
  comes back, another node may steal. This is by design — if you can't reach the
  DB, you can't guarantee exclusive access.
- **Lost ownership** — If `gate_renew` returns `{:error, :not_owner}` (another
  node stole the claim), the heartbeat stops itself.

**Idempotency guidance:** Since lease expiry can cause a second node to start the
same work, strategies that perform side effects should use idempotency keys. For
DB writes, use unique constraints keyed by the episode's dedupe_key or step
number. For external API calls, include an idempotency header derived from the
episode ID + step number.

### Telemetry events

All events are prefixed with `[:cyclium, :work_claims, ...]`:

| Event | Measurements | Metadata | Meaning |
|-------|-------------|----------|---------|
| `:acquired` | `count`, `duration_ms` | `dedupe_key`, `owner_node` | Fresh claim acquired |
| `:steal` | `count`, `duration_ms` | `dedupe_key`, `owner_node` | Expired claim reclaimed (attempt > 1) |
| `:busy` | `count`, `duration_ms` | `dedupe_key`, `owner_node` | Claim denied — another node holds it |
| `:renewed` | `count` | `dedupe_key`, `owner_node` | Heartbeat renewal succeeded |
| `:renew_failed` | `count` | `dedupe_key`, `owner_node` | Heartbeat renewal failed (lost ownership) |
| `:completed` | `count` | `dedupe_key`, `owner_node` | Work finished, claim released |
| `:failed` | `count` | `dedupe_key`, `owner_node` | Work failed, claim released |

**Key metrics to alert on:**

- `steal` rate > 0 during normal operation → nodes are dying or leases are too
  short
- `busy` rate proportional to node count → expected (N-1 nodes get busy per
  dedupe key)
- `renew_failed` > 0 → possible clock drift or DB contention

### Testing work claims

**Unit tests:** Use `Cyclium.WorkClaims.FakeClaims` — an Agent-backed in-memory
implementation:

```elixir
setup do
  {:ok, _} = Cyclium.WorkClaims.FakeClaims.start_link()
  Application.put_env(:cyclium, :work_claims, Cyclium.WorkClaims.FakeClaims)
  on_exit(fn -> Application.delete_env(:cyclium, :work_claims) end)
end

test "second acquire is busy" do
  assert {:ok, _} = Cyclium.WorkClaims.gate_acquire("key:1", "node-a")
  Cyclium.WorkClaims.FakeClaims.set_busy("key:2")
  assert {:error, :busy} = Cyclium.WorkClaims.gate_acquire("key:2", "node-b")
end
```

**Integration tests (single node):** Configure `EctoClaims` with your test repo.
Verify:

1. Two concurrent `acquire` calls on the same key — one succeeds, one gets `:busy`
2. After `complete`, a new `acquire` on the same key succeeds (reclaim)
3. After lease expiry (set a short lease), `acquire` steals from the previous
   owner

**Multi-node tests:** Deploy to a staging cluster with 2+ nodes. Use a test actor
with a short schedule:

1. Verify only one node's episode runs (check `owner_node` in
   `cyclium_work_claims`)
2. Kill a node mid-episode, wait for lease expiry, verify another node steals and
   completes
3. Monitor telemetry — `steal` events should only appear after the kill, never
   during normal operation

## Node Identity

By default, Cyclium uses `node()` to identify the current BEAM instance for work
claims, trigger requests, and recovery coordination. In environments where
multiple instances share the same Erlang node name (e.g., dev containers all
starting as `app@app`), this breaks lease semantics — every node looks like the
same owner.

`Cyclium.NodeIdentity` provides a pluggable identity layer:

```elixir
# Static override — set per instance via config or env var
config :cyclium, :node_identity, "dev-jane"

# MFA callback for dynamic resolution (hostname, env var, etc.)
config :cyclium, :node_identity, {MyApp.NodeIdentity, :resolve, []}
```

When unconfigured and running in non-distributed mode (`:nonode@nohost`), a
random stable identity is generated per BEAM instance and stored in
`:persistent_term` — unique for the process lifetime but not across restarts.

All work claim operations (`EpisodeTask`, `Heartbeat`, `Runner.Deferred`,
`TriggerRequests.Poller`) use `Cyclium.NodeIdentity.name()` instead of raw
`node()`.

## Multi-Stack Deployments

A **stack** is one logical cyclium cluster that shares a database with other
clusters but runs its own Elixir nodes (its own `Phoenix.PubSub`, its own
in-memory `persistent_term` / ETS registries). Typical reasons to run multiple
stacks against one schema: independent release cadences, blast-radius isolation,
or partitioning actors across regions.

### The library contract is cluster-level

Cyclium itself exposes no per-actor DSL option for stacks. It reads `:stack_slug`
once per cluster, stamps every row its actors produce with that value, and scopes
Recovery to the matching slug. Which actors actually run on a given cluster is the
consumer's decision, implemented in the host app's supervisor.

Episodes, workflow instances, and deferred trigger requests are stamped with the
current `source_stack` at insert time. `Cyclium.Recovery.sweep/1` and
`Cyclium.Recovery.reconcile_workflows/1` read `:stack_slug` by default and only
scan rows from their own stack — this prevents a crashed cluster's work from being
re-driven on a cluster whose `persistent_term` / PubSub state doesn't know about
it.

### Partitioning actors across stacks

The simplest approach is one actor list per deployment:

```elixir
# On the stack_a cluster's host app:
config :cyclium, :stack_slug, System.get_env("CYCLIUM_STACK_SLUG")   # "stack_a"
config :my_app, :cyclium_actors, [StackAOnlyActor, SharedActor]

# On the stack_b cluster's host app:
config :cyclium, :stack_slug, System.get_env("CYCLIUM_STACK_SLUG")   # "stack_b"
config :my_app, :cyclium_actors, [StackBOnlyActor, SharedActor]
```

A richer approach declares the allowed stacks on each actor's child-spec and has
the supervisor filter the list at init time — useful when the same release is
deployed to every cluster and you want a single source of truth for which actor
runs where:

```elixir
config :my_app, :cyclium_actors, [
  {SharedActor, []},
  {StackAOnlyActor, stacks: [:stack_a]},
  {CrossStackActor, stacks: [:stack_a, :stack_b]}
]

# In the supervisor's init/1:
stack = Application.get_env(:cyclium, :stack_slug)
children = Enum.filter(configured_actors, &actor_runs_on_stack?(&1, stack))
```

Either pattern is fine — cyclium doesn't care how the list was built, only what
actually gets supervised. Because each cluster has its own node processes,
PubSub, and `persistent_term` cache, a stack-local actor's strategy / budget /
log-strategy lookups only exist on the cluster that supervises it — which is
exactly why Recovery must be stack-scoped.

### Runtime configuration

For a single release that can be deployed into multiple stacks, drive the slug
from an env var in `runtime.exs`:

```elixir
# runtime.exs
config :cyclium, :stack_slug, System.get_env("CYCLIUM_STACK_SLUG")
```

Leaving `:stack_slug` unset (or `nil`) is the single-stack default: rows are
stamped `NULL` and Recovery scans without a stack filter. Pre-migration rows with
`NULL` `source_stack` are swept by any stack for one release so legacy episodes
aren't orphaned — once all rows have been stamped, you can tighten Recovery by
stamping a real slug on every cluster.

### Related config

- `:stack_slug` — identity of *this* cluster (stamps rows and scopes Recovery)
- `:trigger_poll_source_stack` — separate filter on `TriggerRequests.Poller`:
  which stacks' deferred requests this full-mode node will pick up (often the same
  value as `:stack_slug`, but can be broader)
- `:trigger_poll_source_env` — env filter on the poller; **defaults to
  `Cyclium.Env.current()`** (this node's env, strict equality), so set it only to
  poll a *different* env than the node runs as (see the `:env` section below)
- `Cyclium.StackSlug.current/0` — read the slug; returns `nil` when unset

## Per-node dedup identity (`:env`)

Stack slug controls *which actors run* and is shared by all nodes of a stack —
so two `:full` nodes of the same stack against the same DB still dedup each other
out (only one wins each episode/claim). That's correct for a real cluster, but
not when you want a developer's laptop and a hosted test node to **each run their
own** episodes of the same actor against a shared dev database.

`config :cyclium, :env` is an optional per-node identity, orthogonal to the stack
slug. When set, each env operates as an **independent world** against the shared
DB; when unset, behavior is **byte-identical** to single-env operation (legacy
`NULL` rows belong to the unset/default env).

```elixir
# runtime.exs — set on the isolated node (dev laptop, RC); leave unset on prod
config :cyclium, :env, System.get_env("CYCLIUM_ENV")
```

`:env` scopes work along three dimensions (it does **not** affect actor
placement — that's `:stack_slug`):

1. **Dedup / claim keys** — folded into the episode `dedupe_key` (which the
   work-claim lease and derived output keys inherit) and explicit output keys, so
   each env creates and runs its own episodes and holds its own leases.
2. **Recovery** — episodes and workflow instances carry `source_env` (mirroring
   `source_stack`). `Cyclium.Recovery.sweep/1` and `reconcile_workflows/1` default
   `source_env` to `Cyclium.Env.current()` and match it by **strict equality** —
   so an env-tagged node never resurrects the default node's orphans, and
   vice-versa. (Contrast `source_stack`, where `NULL` means "match any stack".)
3. **Findings** — each env keeps its own active finding per key (`cyclium_findings.env`
   + a `[finding_key, status, env]` unique index). `Cyclium.Findings` reads and
   upserts are cordoned to the current env, and a finding inherits the env of the
   episode that raised it (`episode.source_env`).
4. **Deferred triggers** — `cyclium_trigger_requests` carry `source_env` (inherited
   from the deferring episode). The `TriggerRequests.Poller` defaults its filter to
   `Cyclium.Env.current()` (strict equality), so each env's trigger-only nodes feed
   only that env's full nodes. Override with `:trigger_poll_source_env`.

This makes an **RC node sharing prod's DB** viable: configure it `:full` with
recovery on and `env: "rc"` (same stack slug as prod). It drives UI interactions
and runs actors fully independently — prod (`env` unset) and RC neither dedup,
recover, nor clear each other's work. (Keep heavy ETL off RC; gate it by env or
leave those actors out of RC's placement.)

`Cyclium.Env.current/0` reads the value; returns `nil` when unset.

### Operating across envs (demo / staging backfill)

The scope is **per-call overridable**, so a dev or Mix task can seed or inspect
another env from any node without changing that node's config. The env (and
stack) flow through plain attrs/opts:

```elixir
# Seed a demo-env episode from any node. A finding raised against it inherits
# the episode's env, so the finding lands in "demo" automatically:
{:ok, episode} =
  Cyclium.Episodes.create(%{
    actor_id: "resource_monitor",
    expectation_id: "check_resource_limits",
    trigger_type: :manual,
    status: :running,
    started_at: DateTime.utc_now() |> DateTime.truncate(:second),
    source_stack: "hatch",
    source_env: "demo"
  })

Cyclium.Findings.persist_finding({:raise, params}, episode)   # → finding.env == "demo"

# Inspect another env's findings without being that env:
Cyclium.Findings.active_for([class: "limit_breach"], env: "demo")

# Drive recovery/reconciliation for another env/stack from a one-off task:
Cyclium.Recovery.sweep(source_stack: "hatch", source_env: "demo")
```

Reads default to `Cyclium.Env.current()`; pass `env:` to target another env
explicitly (`env: nil` targets the unset/default env). Writes follow the
episode's `source_env`, so backfilling is just "create the episode in the target
env, then persist against it."

## Trigger-Only Mode (deferred execution)

In shared environments — dev machines on a common test DB, QC/sandbox instances,
CI — running cyclium actors on every node leads to competing work claims and
unpredictable execution. Conversely, disabling cyclium entirely on non-processing
nodes leaves the UI hobbled: episodes never fire, statuses never update.

Trigger-only mode solves both problems by decoupling event processing from
episode execution.

### Three operating modes

| Mode | Actors start? | Events flow? | Episodes execute locally? | Trigger requests written? |
|------|-------------|-------------|--------------------------|--------------------------|
| `:full` | yes | yes | yes | no (direct) |
| `:trigger_only` | yes | yes | no | yes (to DB) |
| `:disabled` | no | no | no | no |

### How it works

In **`:trigger_only`** mode, the actor supervision tree starts normally — Bus
subscriptions, schedule timers, debounce, circuit breakers all work. But the
runner is swapped to `Cyclium.Runner.Deferred`, which writes a row to
`cyclium_trigger_requests` instead of spawning a Task. The episode record is still
created in the DB so the UI can display it.

On **`:full`** mode nodes, a `Cyclium.TriggerRequests.Poller` watches the trigger
requests table and dispatches deferred episodes to `Runner.OTP` for local
execution. The poller uses `WorkClaims.gate_acquire/3` (with dedupe key
`"trigger_request:<id>"`) to coordinate dispatch across nodes — only one
full-mode node will pick up a given request. If work claims are not configured,
the poller falls through to passthrough mode. The poller can be scoped by
`source_stack` to only pick up requests from specific stacks.

### Configuration

```elixir
# Host app config — set per environment
config :my_app, :cyclium_mode, :full          # :full | :trigger_only | :disabled

# On full-mode nodes: enable the poller
config :cyclium, :trigger_poller, true
config :cyclium, :trigger_poll_interval_ms, 5_000      # default
config :cyclium, :trigger_poll_source_stack, "stack_a"   # nil = pick up all

# On trigger-only nodes: runner is set automatically
# config :cyclium, :runner, Cyclium.Runner.Deferred
# config :cyclium, :stack_slug, :stack_a
```

### Deployment scenarios

**Dev machines + shared test DB:**

- QC/test node runs `:full` with the poller enabled
- Dev machines run `:trigger_only` — events flow, UI works, episodes defer to the
  processing node
- A dev who wants to process locally overrides to `:full` and narrows their actor
  list

**Sandbox / feature-branch testing:**

- Sandbox runs `:trigger_only` — UI flows complete, episode records exist, Bus
  events fire
- Designated processing node runs `:full` and picks up deferred triggers

**Production (unchanged):**

- All nodes run `:full` as before; work claims handle multi-node coordination
- The trigger requests table stays empty

### Database table

The `cyclium_trigger_requests` table (V14 migration):

| Column | Type | Notes |
|--------|------|-------|
| `episode_id` | binary_id | FK to `cyclium_episodes` |
| `actor_id` | string | Actor that created the trigger |
| `expectation_id` | string | Expectation that fired |
| `source_node` | string | Node identity of the trigger-only instance |
| `source_stack` | string | Stack slug for scoped polling |
| `status` | string | `pending`, `claimed`, `completed`, `expired` |
| `opts` | map | Runner options (e.g., resume flag) |
| `claimed_by` | string | Node identity of the full-mode instance |

Indexed on `(status, inserted_at)` for efficient polling.

### Runtime mode switching

`Cyclium.Mode` supports live mode changes without restart — both node-wide and
per-actor:

```elixir
# Switch the whole node (via remote console, admin endpoint, etc.)
Cyclium.Mode.set(:trigger_only)   # stop local execution, defer to DB
Cyclium.Mode.set(:full)           # resume local execution + polling

# Per-actor override — yield one actor to another node while keeping the rest
Cyclium.Mode.set_actor_override(:resource_monitor, :trigger_only)
Cyclium.Mode.clear_actor_override(:resource_monitor)
Cyclium.Mode.clear_all_overrides()

# Inspect current state
Cyclium.Mode.status()
# %{node_mode: :full, overrides: %{resource_monitor: :trigger_only}, node_identity: "..."}
```

Mode reads are ETS-backed (`read_concurrency: true`) for zero overhead in hot
paths. The trigger request poller self-gates on each cycle — it only polls when
the node-wide mode is `:full`.

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Dynamic Actors](dynamic_actors.md) · [Advanced](advanced.md) (checkpointing,
circuit breaker, step retry)

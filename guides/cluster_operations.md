# Cluster Operations

Cyclium runs stateful episodes on an ordinary cluster of application nodes:
no job queue, no Redis, no leader election. The database is the only shared
state, and five mechanisms built on it keep the cluster honest:

| Mechanism | Question it answers | Backing |
|---|---|---|
| Node identity | "Which process am I, as seen by the other nodes?" | `Cyclium.NodeIdentity` |
| Work claims | "Is anyone else already running this?" | `cyclium_work_claims` leases |
| Recovery | "What was running when a node went away, and who picks it up?" | episode rows + journal recency |
| Stack and env scoping | "Which rows belong to this deployment, and which world of data does it live in?" | `source_stack`, `source_env`, `env` columns |
| Trigger-only mode | "Can a node *trigger* work without *running* it?" | `cyclium_trigger_requests` |

The sections below take them in that order, which is also roughly the order in
which a new deployment needs them. Examples use a generic resource domain
(`resource_monitor`, `resource_advisor`).

---

## 1. Node identity

Every coordination row records which node owns it. By default that is
`node()`, which is fine for a properly named distributed cluster and wrong for
anything where several instances boot with the same node name (local
containers that all come up as `app@app`, for instance): two owners that look
identical cannot hold separate leases.

`Cyclium.NodeIdentity.name/0` is what the library uses instead of `node()`, and
it can be overridden per instance:

```elixir
# A fixed string, typically from an env var set per instance
config :cyclium, :node_identity, System.get_env("CYCLIUM_NODE_ID")

# Or a function the library calls on demand
config :cyclium, :node_identity, {MyApp.NodeIdentity, :resolve, []}
```

With nothing configured and the VM running non-distributed
(`:nonode@nohost`), a random identity is minted once per VM and held in
`:persistent_term`: stable while the process lives, different after a restart.

The identity flows into work claims, heartbeats, deferred trigger requests and
the trigger poller; nothing in the library reads `node()` directly for
ownership.

---

## 2. Work claims: at-most-once execution

A work claim is a lease on an episode's `dedupe_key`. When claims are
configured, an episode task has to hold the lease before it runs, keeps it
alive with a heartbeat while it runs, and releases it when it finishes. A node
that dies lets its leases expire, after which another node may take them over.

Claims are **opt-in**. Without configuration every `Cyclium.WorkClaims.gate_*`
call returns a passthrough value and costs nothing.

```elixir
config :cyclium, work_claims: Cyclium.WorkClaims.EctoClaims   # the shipped adapter
config :cyclium, work_claims_lease_seconds: 120               # default
```

### 2.1 Life of a claim

1. `Cyclium.EpisodeTask` calls `gate_acquire/3` with the episode's
   `dedupe_key`. `{:error, :busy}` means another node holds a live lease; the
   task exits normally and the episode is not run here.
2. A `Cyclium.WorkClaims.Heartbeat` process renews the lease every
   `lease / 3` seconds. If a renewal comes back `{:error, :not_owner}` the
   lease was taken from under us; the heartbeat tells the task, which aborts
   before its next step so it cannot deliver outputs twice.
3. Before the post-converge side effects (findings, outputs) the runner
   re-checks ownership at the **fence** it acquired: a monotonic generation
   that increments on every acquire and steal. A lease that was stolen and
   then re-acquired by the same node (A → B → A) carries a newer fence and is
   treated as lost.
4. On completion the claim is set to `:done`; on a crash to `:failed`.

The same gate serialises two other things: the trigger poller claims
`"trigger_request:<id>"` before dispatching a deferred episode, and the
recovery sweep claims an orphan's key before restarting it.

### 2.2 The shipped adapter

`Cyclium.WorkClaims.EctoClaims` is race-free on READ COMMITTED without row
locks. A new claim is an `INSERT` whose unique index on `dedupe_key` turns a
concurrent first acquire into `:busy`; every takeover is one conditional
`UPDATE ... WHERE <the state we read still holds>`, and zero rows affected
means someone else won. An expired lease is not a separate state: it is a
`:claimed` row whose `lease_until` has passed, and the takeover path steals it
in place.

The table (`V6`, widened by `V21`):

| Column | Meaning |
|---|---|
| `dedupe_key` (unique) | the episode's dedupe key, or a poller / sweep key |
| `state` | `claimed`, `done`, `failed` |
| `owner_node` | `Cyclium.NodeIdentity.name/0` of the holder |
| `lease_until`, `last_heartbeat_at` | lease bookkeeping |
| `attempt` | how many times the key has been acquired or stolen |
| `fence` | ownership generation checked before side effects |
| `work_type` | `"episode"`, `"trigger_request"`, `"recovery"`, `"sweep"` |

A custom adapter implements the `Cyclium.WorkClaims` behaviour
(`acquire/3`, `renew/3`, `complete/2`, `fail/3`, `reclaim_expired/1`, and
optionally `owns?/3` for the fence check). A SQL Server deployment may add
`UPDLOCK` / `READPAST` hints for throughput; correctness does not need them.

### 2.3 Choosing a lease length

The lease is the longest a dead node's work stays unavailable to the rest of
the cluster, and `lease / 3` is how often every running episode writes a
heartbeat row.

| Lease | Takeover after a crash | Heartbeat every | Fits |
|---|---|---|---|
| 60 s | about a minute | 20 s | short episodes, fast failover |
| 120 s (default) | about two minutes | 40 s | most workloads |
| 300 s | about five minutes | 100 s | long steps, unreliable networks |

Keep the lease at least three times the worst database round trip you expect;
if partitions of thirty seconds or more are routine, lengthen it so they do
not cause false steals. A stolen episode is restarted by the thief from its
latest checkpoint (or from `init/2`), so strategies with side effects should
be idempotent: unique constraints keyed on the dedupe key or step number for
database writes, an idempotency header derived from episode id and step number
for external calls.

### 2.4 What the heartbeat does when things go wrong

| Failure | Effect |
|---|---|
| heartbeat process crashes | the linked task restarts it; the lease still has two thirds of its window |
| episode task crashes | the heartbeat dies with it and the rescue path marks the claim `:failed`; after a hard kill the lease simply expires |
| database unreachable | renewals fail, the lease expires, another node may steal once the database returns; by design, since exclusivity cannot be proven without it |
| renewal returns `:not_owner` | the heartbeat stops and signals the task to abort before further side effects |

### 2.5 Watching claims

Telemetry under `[:cyclium, :work_claims, ...]`: `:acquired`, `:steal`,
`:busy`, `:renewed`, `:renew_failed`, `:completed`, `:failed`, each with
`dedupe_key` and `owner_node` metadata. Two readings matter in production:

- any `:steal` outside a deploy or incident means nodes are dying or leases
  are too short;
- `:busy` scaling with node count is normal (every other node loses each key
  once), while `:renew_failed` above zero points at clock drift or contention.

For tests, `Cyclium.WorkClaims.FakeClaims` is an in-memory adapter whose
`set_busy/1` simulates contention. An integration check against a real repo
should confirm that two acquires on one key yield one success and one `:busy`,
that a key can be re-acquired after `complete`, and that a short lease is
stolen once it lapses.

---

## 3. Recovery

### 3.1 How an episode gets orphaned

A node that stops leaves its running episodes as `:running` rows. Two kinds of
stop look different afterwards:

- **Hard stop** (crash, out-of-memory kill, `kill -9`). The task never runs
  its exit path. The row has no marker; the sweep notices it once its step
  journal has been quiet for `stale_after_ms`.
- **Graceful stop** (a deploy's SIGTERM, a supervisor shutdown).
  `Cyclium.EpisodeDrainer`, which stops before the episode tasks do, stamps
  every running episode in three statements: `phase = "interrupted"`, this
  node's claims released, one `:observation` journal marker
  (`result_ref["event"] == "interrupted"`) each. It then tells the tasks to
  stop without writing anything. The sweep treats the stamped phase as stale
  immediately, so the restart does not wait out the recency window. A task
  still mid-step when `config :cyclium, :episode_shutdown_ms` (default 5 s)
  runs out is killed, but it was already stamped, so it too restarts promptly.

A step is usually one model call, so five seconds rarely lets one finish.
Raise the window where the platform allows it (the orchestrator's own stop
timeout must be longer still):

```elixir
config :cyclium, :episode_shutdown_ms, :timer.seconds(30)
```

### 3.2 The sweep

`Cyclium.Recovery.sweep/1` runs on every node after boot (give the cluster a
minute or two to settle first):

1. list `:running` episodes whose newest journal step is older than
   `stale_after_ms` (default two minutes), or whose phase is `"interrupted"`;
2. shuffle the list, so nodes that woke on the same timer do not all race for
   the same first row;
3. claim each one with a single `UPDATE ... WHERE status = 'running'` that
   sets `phase = "recovering"` and increments `attempts` (one row affected
   means this node owns the recovery; zero means another node got there);
4. apply the expectation's `recovery_policy`:
   - `:restart` re-enqueues the episode with `resume: true`, so it continues
     from its latest checkpoint or from `init/2`. The claim the sweep took is
     completed first, because the shipped adapter does not let a holder
     re-acquire its own live lease. A `"resumed"` marker is journaled so a step
     feed shows the interruption and the restart. When `attempts` has passed
     the episode's `max_attempts` (default 3) the episode is failed as
     `orphaned` instead: the cap on an episode bouncing between nodes across a
     rolling deploy.
   - `:fail` (the default) marks the episode `:failed` with
     `error_class: "orphaned"` and closes the journal the same way the runner
     does.
5. emit `[:cyclium, :recovery, :sweep]` with the counts.

A restart is handed to the actor's live process (`{:recover_episode, id}`)
when one can be found, so recovered work runs under
`max_concurrent_episodes` and the actor's queue exactly like a fresh trigger.
Recovered episodes are queued, never dropped or shed. Without a reachable
actor process the sweep enqueues directly.

The policy is read from the compiled actor module when the sweep is given an
`actor_registry`, otherwise from the actor's definition row (dynamic actors),
otherwise `:fail`. Choose `:restart` for strategies that re-read their inputs
and are safe to repeat; keep `:fail` for anything whose side effects are not
idempotent.

```elixir
actor do
  expectation(:check_resource_limits,
    strategy: MyApp.Strategies.ResourceLimits,
    trigger: {:event, "resource.updated"},
    recovery_policy: :restart
  )
end
```

### 3.3 Wiring it in

```elixir
# identifier() string of each compiled actor → its module
@actor_registry %{
  "resource_monitor" => MyApp.Actors.ResourceMonitor,
  "resource_advisor" => MyApp.Actors.ResourceAdvisorActor
}

children = [
  {Cyclium.Supervisor, pubsub: MyApp.PubSub},
  MyApp.Actors.ResourceMonitor,
  MyApp.Actors.ResourceAdvisorActor,
  {Task,
   fn ->
     Process.sleep(:timer.minutes(2))
     Cyclium.Recovery.sweep(actor_registry: @actor_registry)
     Cyclium.Recovery.reconcile_workflows()
   end}
]
```

`:resolve_policy` (a function of the episode) replaces the registry lookup
when the policy depends on more than the expectation.

### 3.4 Workflows that missed an event

The workflow engine advances a workflow only when it sees the terminal Bus
event of a step's episode. An engine that was not running when the event fired
leaves the instance `:running` with a step still marked `"running"`.
`Cyclium.Recovery.reconcile_workflows/0` walks `:running` and `:blocked`
instances, loads the episode behind each `"running"` step, and re-broadcasts
the terminal event for any episode that has already finished; the engine then
handles it through its normal path. Run it after `sweep/1`, once workflow
modules and dynamic workflows are registered.

### 3.5 One episode per trigger across the cluster

Every node receives every Bus event, so every node's actor would create an
episode for the same trigger. Two database guarantees prevent that:

- **Deterministic dedupe keys.** A schedule trigger keys on
  `schedule:<actor>:<expectation>:<bucket>` (the window, or the cron tick to
  the minute); an event trigger keys on
  `event:<actor>:<expectation>:<payload hash>`. A filtered unique index on
  `dedupe_key` (`WHERE dedupe_key IS NOT NULL AND archived_at IS NULL`) lets
  one insert through and turns the others into a constraint error the actor
  logs at debug level and drops. Archived episodes are outside the index, so
  re-triggering old work is never blocked.
- **Jitter.** Each actor sleeps a random 0–200 ms before inserting, so the
  fastest node does not win every key.

Together with the recovery claim and the per-node shuffle:

| Situation | Guarantee |
|---|---|
| the same trigger seen by N nodes | exactly one episode row |
| the same orphan seen by N nodes | exactly one node recovers it |
| recovered `:restart` work | runs at the actor's normal per-node capacity |
| archived episodes | do not block a new episode with the same key |

---

## 4. Stacks and envs: scoping rows to a deployment

Two optional identities decide which rows a node considers its own. They are
independent and solve different problems.

### 4.1 Stack slug: which cluster runs which actors

A **stack** is one logical cluster (its own nodes, PubSub and in-memory
registries) sharing a database with other clusters. Cyclium reads
`config :cyclium, :stack_slug` once per cluster, stamps it onto every episode,
workflow instance and deferred trigger request as `source_stack`, and scopes
`Cyclium.Recovery.sweep/1` and `reconcile_workflows/1` to rows with the same
slug. The reason is that an actor's strategy, budget and configuration live in
the `persistent_term` registry of the cluster that supervises it; a sweep on
another cluster could not run its work.

Which actors start on which stack is the host application's decision. Either
keep one actor list per deployment, or declare allowed stacks on each child
spec and filter in the supervisor:

```elixir
# runtime.exs, same release everywhere
config :cyclium, :stack_slug, System.get_env("CYCLIUM_STACK_SLUG")   # "stack_a", "stack_b", ...

config :my_app, :cyclium_actors, [
  {SharedActor, []},
  {StackAOnlyActor, stacks: [:stack_a]},
  {CrossStackActor, stacks: [:stack_a, :stack_b]}
]

# supervisor init/1
stack = Cyclium.StackSlug.current()
children = Enum.filter(configured_actors, &actor_runs_on_stack?(&1, stack))
```

An unset slug is the single-stack default: rows are stamped `NULL` and
recovery is unscoped. Rows stamped `NULL` from before the column existed are
swept by any stack, so legacy episodes are not orphaned by the upgrade.

Related: `:trigger_poll_source_stack` narrows the trigger poller (section 5)
to requests from given stacks, and `Cyclium.StackSlug.current/0` reads the
slug (`nil` when unset).

### 4.2 Env: independent worlds in one database

Two `:full` nodes of the **same** stack against the same database dedup each
other: one wins each episode, one holds each lease. That is right for a
production cluster and wrong for a developer's machine sharing a test database
with a hosted node, where each should run its own episodes of the same actor.

`config :cyclium, :env` is a per-node identity for exactly that. Unset, the
library behaves byte-for-byte as before and legacy `NULL` rows belong to the
unset env. Set, the node operates as its own world along four axes:

1. **Keys.** The env is appended to episode dedupe keys (which leases and
   derived output keys inherit) and to explicit output keys, via
   `Cyclium.Env.scope_key/1`.
2. **Recovery.** Episodes and workflow instances carry `source_env`; sweep and
   reconciliation default to the node's env and match it by **strict
   equality** (unlike `source_stack`, where `NULL` matches any stack), so an
   env-tagged node never resurrects the default node's work or the reverse.
3. **Findings.** `cyclium_findings.env` plus a `[finding_key, status, env]`
   unique index give each env its own active finding per key. A finding
   inherits the env of the episode that raised it; reads default to the
   node's env.
4. **Deferred triggers.** Trigger requests inherit the deferring episode's env
   and the poller defaults to its own env, so each env's trigger-only nodes
   feed only that env's full nodes (`:trigger_poll_source_env` overrides).

```elixir
# runtime.exs: set on the isolated node, leave unset on the shared one
config :cyclium, :env, System.get_env("CYCLIUM_ENV")
```

A release-candidate node can therefore run `:full` with recovery on against
production's database, tagged `env: "rc"`, and neither side will dedup,
recover or clear the other's work. Keep heavy batch actors out of such a
node's placement.

### 4.3 Acting on another env or stack

Scope is per call, so a one-off task can seed or inspect another env from any
node:

```elixir
{:ok, episode} =
  Cyclium.Episodes.create(%{
    actor_id: "resource_monitor",
    expectation_id: "check_resource_limits",
    trigger_type: :manual,
    status: :running,
    started_at: DateTime.utc_now() |> DateTime.truncate(:second),
    source_stack: "stack_a",
    source_env: "demo"
  })

# A finding raised against that episode lands in "demo".
Cyclium.Findings.persist_finding({:raise, params}, episode)

# Read another env's findings; env: nil targets the unset/default env.
Cyclium.Findings.active_for([class: "limit_breach"], env: "demo")

# Recover another stack/env from here.
Cyclium.Recovery.sweep(source_stack: "stack_a", source_env: "demo")
```

---

## 5. Trigger-only mode

On a shared database (developer machines, review environments, CI) it is
often wrong for every node to *run* episodes, yet turning Cyclium off entirely
leaves the host's UI dead: nothing fires, nothing updates. Trigger-only mode
separates triggering from executing.

| Mode | Actors start | Events flow | Episodes run here | Trigger requests written |
|---|---|---|---|---|
| `:full` | yes | yes | yes | no |
| `:trigger_only` | yes | yes | no | yes |
| `:disabled` | no | no | no | no |

In `:trigger_only` the actor tree starts normally (subscriptions, timers,
debounce, circuit breakers), the episode row is still created so the UI can
show it, but the runner is `Cyclium.Runner.Deferred`, which writes a
`cyclium_trigger_requests` row instead of starting a task. On `:full` nodes,
`Cyclium.TriggerRequests.Poller` reads pending requests (oldest first, in
batches), claims `"trigger_request:<id>"` through work claims so only one full
node dispatches each, and hands the episode to `Cyclium.Runner.OTP`. Requests
left pending for an hour are expired. The poller only polls while the node's
mode is `:full`, and filters by `source_env` (defaulting to its own) and
optionally `source_stack`.

```elixir
config :cyclium, :mode, :trigger_only           # or :full / :disabled
config :cyclium, :trigger_poll_interval_ms, 5_000
config :cyclium, :trigger_poll_source_stack, "stack_a"   # nil picks up every stack
```

Request rows carry the episode id, actor and expectation, the deferring node's
identity, `source_stack`, `source_env`, a `status` of `pending` / `claimed` /
`completed` / `expired`, the runner options (such as `resume`), and
`claimed_by`; the table is indexed on `(status, inserted_at)` and
`(status, source_env, inserted_at)`.

Typical placements:

- a shared test node runs `:full` with the poller; developer machines run
  `:trigger_only`, so their UIs work while execution lands on the test node;
  a developer who wants local execution switches to `:full` and trims the
  actor list;
- a review environment runs `:trigger_only` and a designated node processes
  its requests;
- production runs `:full` everywhere, with work claims handling
  coordination, and the request table stays empty.

The mode can change at runtime, node-wide or per actor, with ETS-backed reads
that cost nothing on the hot path:

```elixir
Cyclium.Mode.set(:trigger_only)
Cyclium.Mode.set(:full)
Cyclium.Mode.set_actor_override(:resource_monitor, :trigger_only)
Cyclium.Mode.clear_actor_override(:resource_monitor)
Cyclium.Mode.status()
# => %{node_mode: :full, overrides: %{resource_monitor: :trigger_only}, node_identity: "..."}
```

---

## 6. What the shared tables are

Several tables are not logs but **execution state**: a node that restarts an
episode reads its last checkpoint from `cyclium_episode_checkpoints` and, for
an approval, the plan from `cyclium_episode_steps`; the workflow engine
advances on `cyclium_workflow_instances.step_states`; the poller runs whatever
`cyclium_trigger_requests` names. Anyone with write access to those tables
decides what runs next. Treat write access to the schema as equivalent to
code-deploy access when several deployments share one database, and keep
plans re-validated on resume (the agentic templates do) so a tampered journal
entry still has to pass the gate.

---

## 7. A deploy, end to end

1. The orchestrator sends SIGTERM; the VM has the configured stop window.
2. The drainer stamps running episodes `interrupted`, releases their claims
   and journals a marker, then asks the tasks to stop.
3. Tasks that finish their step inside `:episode_shutdown_ms` stop cleanly;
   the rest are killed, already stamped.
4. New nodes boot, wait for the cluster to settle, and run
   `Cyclium.Recovery.sweep/1` then `reconcile_workflows/0`.
5. Each stamped or stale episode is claimed by exactly one node and restarted
   or failed per its `recovery_policy`; workflow steps whose episodes finished
   during the window get their events replayed.

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Dynamic Actors](dynamic_actors.md) · [Observability](observability.md) ·
[Advanced](advanced.md)

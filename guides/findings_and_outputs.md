# Findings, Outputs, and the Bus

Findings are the persistent observations an episode produces; outputs are the
typed actions it proposes; the Bus is the event stream that connects everything.
This guide also covers LiveView integration and the `Window` dedup helpers.

> Examples use a generic **resource monitoring** domain (`resource_monitor`
> actor, `resource:limits:#{id}` finding keys).

## Findings

A **finding** is a persistent observation about an entity. Findings have a
lifecycle:

- **Raise** — create or update an active finding (upsert by `finding_key`)
- **Update** — modify mutable fields on an active finding
- **Clear** — mark a finding as resolved (idempotent)

```elixir
# In your converge/2 callback:
findings: [
  {:raise, %{
    actor_id: "resource_monitor",
    finding_key: "resource:limits:123",
    class: "over_limit",
    severity: :high,          # :low | :medium | :high | :critical
    confidence: 1.0,
    subject: %{kind: "resource", id: "123"},
    subject_kind: "resource",   # denormalized for SQL Server compat
    subject_id: "123",
    summary: "Resource is over its allocated limit",
    evidence_refs: %{"percent_used" => 1.12}
  }},
  {:update, "resource:limits:123", %{confidence: 0.8}},
  {:clear, "resource:limits:123"},
  {:clear, "resource:limits:123", "limit raised by operator"}
]
```

### Finding key scoping: deduplicated vs distinct

The `finding_key` controls deduplication. An active finding with the same key is
updated in place (last-writer-wins on mutable fields). Choose your key strategy
based on intent:

- **Deduplicated (default pattern):** Use a stable key like
  `"resource:limits:123"`. Repeated episodes update the same active finding —
  ideal for ongoing status tracking where you want one finding per subject.
- **Distinct per episode:** Include the episode ID in the key, e.g.
  `"resource:limits:123:#{episode.id}"`. Each episode creates a separate
  finding — useful for audit trails or point-in-time snapshots where every run
  should produce its own record. **Lifecycle caveat:** because the key is unique
  per run, a later episode never updates, supersedes, or `{:clear, ...}`s it —
  these findings only accumulate. `active_for(subject:)` will then return one
  active row per run, so bound them with a `ttl_seconds` (auto-clear via the
  finding sweep) or archive them, or you'll grow an unbounded active set. Reach
  for distinct keys only when you actually want point-in-time history; for
  ongoing status tracking, the deduplicated stable key is almost always right.

The `episode_ctx` map passed to `converge/2` contains `episode_id`, so you can
reference it directly:

```elixir
# Deduplicated: one active finding per resource, updated each run
def converge(state, _episode_ctx) do
  {:ok, %Cyclium.ConvergeResult{
    findings: [{:raise, %{finding_key: "resource:limits:#{state.resource_id}", ...}}]
  }}
end

# Distinct: one finding per episode run
def converge(state, episode_ctx) do
  {:ok, %Cyclium.ConvergeResult{
    findings: [{:raise, %{finding_key: "resource:limits:#{state.resource_id}:#{episode_ctx.episode_id}", ...}}]
  }}
end
```

### Querying findings

```elixir
Cyclium.Findings.active_for(actor: "resource_monitor")
Cyclium.Findings.active_for(subject: %{kind: "resource", id: "123"})
Cyclium.Findings.active_for(finding_key: "resource:limits:123")
Cyclium.Findings.active_for(class: "over_limit")
Cyclium.Findings.active_for(caused_by: "parent:finding:key")
```

### Causality chains

Findings can reference a parent finding via `caused_by_key`. This enables tracing
root causes through chains of related findings:

```elixir
# Raise a child finding linked to a parent
{:raise, %{finding_key: "resource:limits:R-123", caused_by_key: "provider:degraded:acme", ...}}

# Query helpers
Cyclium.Findings.caused_by("parent:key")        # direct children
Cyclium.Findings.causal_chain("child:key", 10)   # walk chain upward (max depth)
Cyclium.Findings.root_cause("child:key")         # find root (no caused_by_key)
```

### TTL / expiration

Findings can auto-expire after a duration. Declare a default TTL on the
expectation, or pass `ttl_seconds` / `expires_at` per finding:

```elixir
# Default TTL for all findings raised by this expectation
expectation(:check_signal,
  strategy: MyApp.Strategies.SignalCheck,
  trigger: {:event, "signal.updated"},
  finding_ttl_seconds: 3600
)

# Or override per finding in converge:
{:raise, %{finding_key: "signal:alert:123", ttl_seconds: 7200, ...}}
```

Expired findings are cleared and active findings are escalated by
`Cyclium.Findings.FindingSweep`, an optional GenServer that runs on a
configurable interval:

```elixir
# config/config.exs
config :cyclium, :finding_sweep, true
config :cyclium, :finding_sweep_interval_ms, 300_000   # 5 minutes (default)
config :cyclium, :finding_sweep_batch_size, 100         # per sweep (default)
```

### Severity escalation

Time-based rules automatically escalate finding severity based on how long a
finding has been active. Declare rules on the expectation:

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: {:event, "resource.updated"},
  escalation_rules: %{
    "limit_risk" => [
      %{after_minutes: 60, escalate_to: :high},
      %{after_minutes: 1440, escalate_to: :critical}
    ]
  }
)
```

Escalation runs as part of the finding sweep cycle. Each sweep interval, **every
active finding** matching a registered escalation pair (actor + expectation +
classes) is loaded from the database and checked against the time-based rules.
This means the sweep interval (`finding_sweep_interval_ms`) controls how often
escalation is evaluated — rules with `after_minutes` granularity finer than the
sweep interval won't fire any faster. For expectations with many active findings,
keep this in mind when tuning the sweep interval and batch size. Application
config (`config :cyclium, :escalation_rules`) is supported as a fallback.

### Post-raise enrichment

An optional callback enriches findings immediately after they're raised. Declare
it on the expectation:

```elixir
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: {:event, "resource.updated"},
  finding_enrichment: fn finding, _episode ->
    {:ok, %{summary: "Enriched: #{finding.summary}", confidence: 0.95}}
  end
)

# Or use a module/function tuple:
expectation(:check_resource_limits,
  strategy: MyApp.Strategies.ResourceLimits,
  trigger: {:event, "resource.updated"},
  finding_enrichment: {MyApp.FindingEnricher, :enrich}
)
```

The callback receives `(finding, episode)` and returns `{:ok, %{...}}` or
`:skip`. Only safe fields are applied: `evidence_refs`, `summary`, `confidence`.
Errors in the callback are logged — the finding persists unchanged. Application
config (`config :cyclium, :finding_enrichment`) is supported as a fallback.

## Outputs

Outputs are typed proposals produced during converge. They flow through the
**Output Router**, which deduplicates and delivers through app-provided adapters.

Deduplication keys off `cyclium_outputs.dedupe_key`, which only prevents
double-delivery if the key is **stable across re-runs** of the same work
(recovery restart, a stolen-lease re-run). There are two ways to supply it:

- **`:key`** — a stable, domain-meaningful logical key. The framework derives
  the actual dedupe_key from the episode's own dedupe_key/id + output type + this
  key, so it's re-run-safe by construction. **Prefer this.**
- **`:dedupe_key`** — an explicit, fully-controlled key. Use for
  cross-episode/temporal dedup (e.g. one alert per 4-hour window via
  `Cyclium.Window`), where you deliberately want a key *not* tied to a single
  episode. You own its stability. Takes precedence over `:key` if both are set.

```elixir
# In converge result — recommended: a logical key, made re-run-safe by the framework
outputs: [
  %Cyclium.OutputProposal{
    type: :email,
    key: "limit_alert",
    payload: %{to: "team@co.com", subject: "Resource 123 over limit"},
    requires_approval: false
  }
]

# Explicit key for time-windowed cross-episode dedup
%Cyclium.OutputProposal{
  type: :email,
  dedupe_key: "alert:resource:123:#{Cyclium.Window.bucket(:h4, DateTime.utc_now())}",
  payload: %{to: "team@co.com"}
}
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

The adapter registry provides programmatic access:

```elixir
Cyclium.Output.Adapter.resolve(:email)    # => MyApp.Adapters.Email
Cyclium.Output.Adapter.resolve("slack")   # => MyApp.Adapters.Slack
Cyclium.Output.Adapter.all()              # => [:email, :slack]
```

## Window helpers

`Cyclium.Window` provides clock-aligned deduplication buckets for output
`dedupe_key` construction:

```elixir
Cyclium.Window.bucket(:h4, DateTime.utc_now())   # "2026-02-24T08"  (4-hour windows)
Cyclium.Window.bucket(:h24, DateTime.utc_now())   # "2026-02-24"     (daily)
Cyclium.Window.bucket(:h48, DateTime.utc_now())   # "2026-02-24"     (every-other-day)
Cyclium.Window.bucket(:w1, DateTime.utc_now())    # "2026-W09"       (ISO week)
```

Use these in `dedupe_key` to prevent duplicate outputs within a time window:

```elixir
dedupe_key: "alert:resource:#{id}:#{Cyclium.Window.bucket(:h4, DateTime.utc_now())}"
```

## Bus

The event bus connects actors, LiveViews, and workflows without coupling. It
wraps Phoenix.PubSub.

```elixir
# Publish a domain event (from your app code):
Cyclium.Bus.broadcast("resource.updated", %{resource_id: "123"})

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

## LiveView integration

Cyclium integrates with Phoenix LiveView via the Bus. Subscribe in your
LiveView's mount and handle events:

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

For richer real-time UI patterns, see [conversation_ui.md](conversation_ui.md)
and [interactive_actors.md](interactive_actors.md).

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Observability](observability.md) · [Workflows](workflows.md)

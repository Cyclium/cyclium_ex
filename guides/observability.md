# Observability

How to see what your episodes are doing: log strategies, the synthesis storage
pipeline, telemetry, the step journal, plus the declarative controls for sampling,
service levels, and adaptive budgets.

> Examples use a generic **resource** domain.

## Log strategies

Set per-expectation via `log_strategy`. Controls both what gets stored in step
journal columns (`args_redacted`, `result_ref`) and what the materialized log
renders:

| Strategy | Step journal `args_redacted` | Step journal `result_ref` | Materialized log |
|---|---|---|---|
| `:none` | omitted | omitted | none |
| `:summary_only` | omitted | omitted | one-line status summary |
| `:timeline` | tool name + action only | summary/IDs only | step-by-step with timestamps |
| `:full_debug` | surviving context after earlier layers | full result payload | timeline + args, results, errors |

Use `:full_debug` for audit-sensitive workflows where you need to reconstruct
exactly what context an LLM had. Use `:timeline` for high-frequency episodes where
you want the flow visible without storing full payloads.

**Important:** `log_strategy` is the last layer in a pipeline. By the time it
runs, earlier layers have already trimmed the data. "Full" in `:full_debug` means
"everything that survived the earlier layers", not necessarily everything the
strategy originally passed. See the pipeline below.

The materialized log is built by `LogProjector` reading back from the
already-stored step rows — it never re-processes the original payload. Whatever
`log_strategy` stored is exactly what appears in the log.

## Storage pipeline for synthesis steps

Every synthesis step passes through three filtering layers in order before
anything reaches the database:

```
synthesis payload from next_step
        │
        ▼
1. __transient__ stripping   — keys listed in :__transient__ are removed from storage
        │                       but the synthesizer receives the full payload
        ▼
2. tool redact callbacks     — redact/1 and redact_result/1 on tool steps
        │                       (not applicable to synthesis, but runs for tool_call steps)
        ▼
3. log_strategy filtering    — controls final shape of args_redacted / result_ref
        │
        ▼
   cyclium_episode_steps (args_redacted, result_ref)
        │
        ▼
   cyclium_episode_logs (rendered by LogProjector from stored step rows)
```

Each layer has a different scope:

| Layer | Controlled by | Purpose |
|---|---|---|
| `__transient__` | Strategy (per synthesis call) | Pass bulk data to LLM without persisting it |
| `redact/1`, `redact_result/1` | Tool module | Trim domain-specific bulky fields from tool steps |
| `log_strategy` | Expectation | Set overall verbosity for the whole episode |

### Transient synthesis data

Sometimes a strategy needs to pass large data to the synthesizer (full record
lists, raw API payloads) that the LLM needs for context but that you don't want
persisted in the step journal or materialized log. Mark those keys under
`:__transient__` in the synthesis payload:

```elixir
def next_step(state, _ctx) do
  records = load_records(state.resource_id)

  {:synthesize, %{
    resource_id: state.resource_id,
    resource_name: state.resource_name,
    record_count: length(records),         # small scalar — kept in storage
    records: serialize_records(records),   # full list — synthesizer needs it, storage does not
    evidence: build_evidence(records),     # small structured summary — kept in storage
    __transient__: [:records]              # strip :records before writing args_redacted
  }}
end
```

The runner passes the full map (minus `:__transient__` itself) to
`synthesizer.synthesize/2`, then drops the listed keys before handing off to
`log_strategy` filtering. The synthesizer receives `records`; the stored step and
rendered log do not, regardless of `log_strategy`.

This is the right tool when:

- You need full detail for synthesis quality (long record lists, raw API
  responses, document text)
- You don't want that data in the audit trail or materialized log
- You still want other context fields (counts, summaries, IDs) persisted for
  debugging

It is not a substitute for `log_strategy` — if you want no storage at all for an
episode type, use `:none` or `:summary_only`. `__transient__` is surgical;
`log_strategy` is wholesale.

Materialized logs are stored in `cyclium_episode_logs` by `Cyclium.LogProjector`
and can be queried via `Cyclium.Episodes.get_log(episode_id)`.

## Telemetry

Cyclium emits 36 structured telemetry events under the `[:cyclium, ...]` prefix.
Attach a handler for development:

```elixir
Cyclium.Telemetry.attach_default_logger()
```

Key events:

| Event | Metadata |
|---|---|
| `[:cyclium, :episode, :completed]` | episode_id, actor_id, output_count, finding_count |
| `[:cyclium, :episode, :failed]` | episode_id, actor_id |
| `[:cyclium, :episode, :sampled_out]` | actor_id, expectation_id |
| `[:cyclium, :step, :tool_call]` | tool, action, episode_id |
| `[:cyclium, :step, :synthesis]` | episode_id |
| `[:cyclium, :finding, :raised]` | finding_key, actor_id, class |
| `[:cyclium, :finding, :cleared]` | finding_key, actor_id, class |
| `[:cyclium, :finding, :expired]` | count |
| `[:cyclium, :finding, :escalated]` | finding_key, actor_id, class |
| `[:cyclium, :finding_sweep, :completed]` | duration_ms, expired_count, escalated_count, node |
| `[:cyclium, :finding_sweep, :failed]` | duration_ms, node, reason |
| `[:cyclium, :output, :delivered]` | type, episode_id |
| `[:cyclium, :actor, :event_received]` | actor_id, event_type |
| `[:cyclium, :actor, :overflow]` | actor_id, policy |
| `[:cyclium, :circuit_breaker, :opened]` | actor_id, expectation_id, consecutive_failures |
| `[:cyclium, :circuit_breaker, :closed]` | actor_id, expectation_id |
| `[:cyclium, :circuit_breaker, :rejected]` | actor_id, expectation_id |
| `[:cyclium, :service_levels, :breach]` | actor_id, expectation_id, type, current, threshold |
| `[:cyclium, :workflow, :step_reused]` | workflow_id, instance_id, step_id, reused_episode_id |

Full list: `Cyclium.Telemetry.events/0`. Work-claim telemetry is documented in the
[Distributed Ops](distributed_ops.md) guide.

## Step journal

Every episode action is recorded as an `EpisodeStep` with one of 16 kinds:

`tool_call`, `synthesis`, `observation`, `checkpoint`, `output_proposed`,
`output_delivered`, `output_failed`, `approval_requested`, `approval_resolved`,
`wait_started`, `wait_resolved`, `finding_raised`, `finding_updated`,
`finding_cleared`, `episode_completed`, `episode_failed`

Each step records: `step_no`, `kind`, `tool_name`, `args_redacted`, `result_ref`,
`error_class`, `error_detail`, `cost_tokens`, `cost_ms`, `created_at`.

Query steps: `Cyclium.Episodes.list_steps(episode_id)`

## Episode sampling

Probabilistic episode firing for high-frequency triggers. Set `sample_rate` on an
expectation to control what fraction of triggers actually fire episodes:

```elixir
expectation(:check_metrics,
  strategy: MyApp.Strategies.MetricsCheck,
  trigger: {:event, "metrics.updated"},
  sample_rate: 0.1  # fire ~10% of triggers
)
```

- `nil` or `1.0` = always fire (default)
- `0.0` = never fire
- Sampled-out episodes emit `[:cyclium, :episode, :sampled_out]` telemetry
- Force-fired episodes bypass sampling

## Service level tracking

Declarative performance objectives with automatic breach detection. Define
success rate and duration thresholds per expectation:

```elixir
expectation(:process_request,
  strategy: MyApp.Strategies.RequestProcessor,
  trigger: {:event, "request.created"},
  service_levels: %{
    max_duration_ms: 30_000,  # p95 target
    success_rate: 0.95,       # 95% success target
    window_episodes: 20       # rolling window size
  }
)
```

Breaches emit `[:cyclium, :service_levels, :breach]` telemetry and a
`"service_levels.breach"` Bus event with details:

```elixir
%{type: :success_rate, current: 0.85, threshold: 0.95}
%{type: :duration, current: 45_000, threshold: 30_000}
```

> **Observation only.** Service levels are purely a monitoring signal — a breach
> emits telemetry and a Bus event, and nothing more. They do **not** throttle,
> back off, fail episodes, open a circuit, or otherwise change execution. To
> *act* on a breach, subscribe to the Bus event (or telemetry) and drive the
> response yourself — page, pause an expectation, trip a circuit breaker, etc.
> For enforcement primitives that do alter execution, see budgets
> (`max_*`), sampling, and circuit breakers in the [Advanced guide](advanced.md).

Query metrics: `Cyclium.ServiceLevels.metrics(actor_id, expectation_id)` returns
`%{success_rate: f, p95_duration_ms: n, sample_count: n}`.

## Adaptive budgets

Advisory budget tracking based on historical episode resource usage. When
enabled, Cyclium records turns, tokens, and wall time for each completed episode
and recommends budgets based on p95 values with 25% headroom.

```elixir
expectation(:classify_item,
  strategy: MyApp.Strategies.ItemClassifier,
  trigger: {:event, "item.created"},
  adaptive_budget: true
)
```

Query recommendations:

```elixir
# After enough samples (minimum 5):
Cyclium.AdaptiveBudget.recommend(actor_id, expectation_id)
# => %{max_turns: 8, max_tokens: 15_000, max_wall_ms: 25_000}

# Detailed stats:
Cyclium.AdaptiveBudget.stats(actor_id, expectation_id)
# => %{samples: 47, p50: %{...}, p95: %{...}, max: %{...}}
```

Adaptive budgets are advisory only — they do not automatically adjust episode
budgets. Use the recommendations to tune your expectation configs over time.

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Findings & Outputs](findings_and_outputs.md) ·
[Distributed Ops](distributed_ops.md)

# Changelog

All notable changes to Cyclium are recorded here. This project uses
[Semantic Versioning](https://semver.org/).

Entries are high-level, not exhaustive. Versions prior to `0.1.4` are
reconstructed from git history and are summarized loosely.

## [0.1.13] — 2026-06-15

### Fixed
- Interactive approval blocks no longer crash the episode. The `"__blocked__"`
  state checkpoint couldn't JSON-encode the interactive strategy's state (it
  carries raw `{:ok, result}` tool-result tuples), and the approval resume path
  was never wired (nothing turned an `approval_resolved` step into the strategy
  proceeding). Resolved by resuming from the journal instead of a state
  checkpoint — see `resume_from_block/2` below. Approving now runs exactly the
  approved plan with no extra LLM round-trip, and survives a node restart.
- `save_checkpoint` is now best-effort: a serialization failure logs and
  continues instead of failing the whole episode.

### Added
- **`Cyclium.Exports`** — durable, downloadable artifacts (e.g. CSVs) an actor
  produces for a principal, fetched via a signed, expiring link. New
  `cyclium_exports` table (migration **V24**), `Cyclium.Schemas.Export`, and
  `create/1` / `fetch_valid/1` / `purge_expired/0` / `sign/1` / `valid_token?/2`
  (HMAC via `:crypto`; 7-day default TTL). Storage + signing only — a consuming
  app serves the bytes behind its own auth.
- Optional `Cyclium.EpisodeRunner.Strategy` callback **`resume_from_block/2`**.
  Strategies that implement it resume a blocked episode from the journal, and
  the runner skips the (potentially unserializable) `"__blocked__"` checkpoint
  for them. Implemented by the interactive template.

### Telemetry
- First-class **`[:cyclium, :episode, :started]`** — fires once, on the owning
  node, with `episode_id`/`actor_id`/`conversation_id` (the old per-node Bus
  fan-out couldn't be used as a metric). A resumed run (e.g. after an approval
  block) emits `[:cyclium, :episode, :resumed]` instead of a second `:started`.
  Added a `duration_ms` measurement to `[:cyclium, :episode, :completed |
  :failed]`.
- **Conversation lifecycle events now fire.** `Cyclium.Conversations` emits the
  declared `[:cyclium, :conversation, :started | :claimed | :resolved |
  :abandoned | :timed_out | :awaiting_participant]` (with `conversation_id`,
  `actor_id`, and `outcome`/`reason` where relevant) alongside the Bus
  broadcasts.
- **`[:cyclium, :step, :synthesis]`** now carries LLM-observability data:
  `duration_ms`, `input_tokens`/`output_tokens`/`total_tokens`, the `model`, and
  `episode_id`/`actor_id`/`conversation_id` — enough to build a `gen_ai` `llm`
  span and attribute cost without a custom adapter. (Emitted after the call;
  previously a bare pre-call count with only `episode_id`.)
- `[:cyclium, :step, :tool_call]` now includes `actor_id`/`conversation_id`, and
  tool-call steps record `cost_ms` (wall time), for `tool` spans.
- `[:cyclium, :actor, :event_received]` no longer fires for the high-frequency
  internal `episode.step_journaled` churn.
- `[:cyclium, :recovery, :sweep]` is now declared in `@events` (was emitted but
  undeclared).

## [0.1.12] — 2026-06-11

### Fixed
- `Conversations.increment_turn/2` now increments atomically (`update_all(inc:)`)
  instead of a read-modify-write, so concurrent episodes converging on the same
  conversation can't clobber each other's `turns_used` / `tokens_used` totals.

### Added
- `@type t :: %__MODULE__{}` on the remaining `Cyclium.Schemas.*` modules
  (Episode, EpisodeStep, EpisodeCheckpoint, EpisodeLog, AgentDefinition, Finding,
  Output, TriggerRequest, WorkflowDefinition, WorkflowInstance) so consumers can
  reference e.g. `Cyclium.Schemas.Episode.t()` in their specs.

## [0.1.11] — 2026-06-11

### Fixed
- Conversation token rollup: `tokens_used` is now rolled up onto the
  conversation after each turn (the converge hook was reading a stale episode
  struct and always saw 0, which also left `max_total_tokens` goal constraints
  inert).

### Changed
- Testkit `assert_valid_actor` / `validate_expectation!` now accept the full
  trigger vocabulary — `:interactive`, `:manual`, `:workflow`, and
  `{:cron, spec}` — so interactive actors validate.

## [0.1.10] — 2026-06-10

### Added
- Episode cancellation: cooperative, distributed, step-boundary cancel
  (`Episodes.request_cancel/2`) so a UI "stop" can interrupt a turn while
  keeping the conversation open.
- Graceful budget exhaustion: optional `handle_budget_exhausted/2` strategy
  callback; interactive turns converge with an "incomplete" summary instead of
  hard-failing (wall-clock exhaustion still hard-fails).
- Multiple interactive expectations per actor: deterministic dispatch
  resolution (explicit option → conversation-pinned `expectation_id` →
  auto-resolve) and a new `expectation_id` column on conversations (migration
  V23).

### Changed
- Expanded the interactive-actors guide (PlanGate layers, failure paths,
  security, `multi_tool_plan`, smoke test).

## [0.1.9] — 2026-06-05

### Fixed
- Scope stale-trigger expiry by `source_env` to stop cross-environment GC of
  trigger requests.

### Changed
- CI/CD and Hex publishing tooling; documentation cleanup.

## [0.1.8] — 2026-06-05

### Added
- Native `{:cron, spec}` expectation trigger (UTC, at-most-once per tick).

### Changed
- Dockerfile / GitLab CI pipeline setup.

## [0.1.7] — 2026-06-04

### Added
- Optional per-node dedup identity (`:env`) for nodes that share a database —
  cordons dedupe/claim/output keys and recovery per environment (migration V22).

### Fixed
- Checkpoint → `handle_result` asymmetry in the runner.

### Changed
- Conversation LiveView helpers bake in the actor-id check; guide ergonomics.

## [0.1.6] — 2026-06-04

### Added
- Framework-derived, re-run-safe output dedupe keys.
- ExDoc + guides in the published docs.

### Fixed
- Work-claim fencing token closes the steal-and-reacquire delivery window;
  stolen episodes abort before delivery; checkpoint taken before blocking steps.
- Wall-clock budget enforced against blocking steps.
- Loop detection requires genuine no-progress, with a per-expectation off switch.
- Idempotent episode-terminal handling in the workflow engine.

## [0.1.5] — 2026-06-04

### Added
- `AtomGuard` for safe atom lookups; wired JSON-defined dynamic triggers.

### Fixed
- Race-free work claims; crash-resilient workflow engine; safe trigger
  atomization; recovery actor lookup made name-independent.
- Output step numbering + microsecond timestamps.

## [0.1.4] — 2026-06-03

### Added
- Enriched episode Bus payloads; `capability_registry` may be given as a map.

### Fixed
- Spread recovery load across nodes instead of concentrating it on one.

## [0.1.0] – [0.1.3] — 2026-03 to 2026-06 (foundational)

Initial framework and early hardening, including:

- Interactive actor framework: strategy template, synthesizer, conversations,
  and intent system.
- Test kit for host apps to validate actors, strategies, synthesizers, outputs,
  workflows, and checkpoint migrations.
- Structured error classification, skip-on-error-class retry policy, and journal
  hardening; runner EXIT handling and tool-execution try/catch.
- `episode.started` Bus event; tool-exec errors pass through the original reason.
- Stack-aware recovery for episodes and workflow instances; prevention of
  duplicate workflow instances across cluster nodes.
- Microsecond precision on episodes; SQL Server text-column fixes;
  `principal_type` on conversations.
- Minimum Elixir lowered to 1.18.

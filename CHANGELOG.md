# Changelog

All notable changes to Cyclium are recorded here. This project uses
[Semantic Versioning](https://semver.org/).

Entries are high-level, not exhaustive. Versions prior to `0.1.4` are
reconstructed from git history and are summarized loosely.

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

# Changelog

All notable changes to Cyclium are recorded here. This project uses
[Semantic Versioning](https://semver.org/).

Entries are high-level, not exhaustive. Versions prior to `0.1.4` are
reconstructed from git history and are summarized loosely.

## [0.3.5] — 2026-08-11

### Changed (behaviour)
- **Context findings are now opt-in and scopable.** Both the `AgenticTask` and
  `Interactive` templates previously seeded context with *every* active finding
  for the actor — an unbounded read that, for a multi-subject actor, leaked
  other subjects' findings into the prompt. Templates now default to
  `context_findings: :none` and accept `:subject` (scoped to this episode's
  subject via the `finding_config` `subject_kind`/`subject_id_key` convention)
  or `:actor` (the previous actor-wide behaviour). A `context_findings_limit`
  (default 50) bounds the row count.
- **`Cyclium.Findings.active_for/2` raises on unrecognized filters** instead of
  silently dropping them. A dropped filter returned a *superset* of what was
  asked for — a wrong result shaped like real data.

### Added
- **Kind-only subject filter** — `active_for(subject: %{kind: "resource"})` now
  matches all findings of a kind regardless of id, instead of falling through
  and returning everything.
- **`:order_by` option on `active_for/2`** (allow-listed columns:
  `:updated_at`, `:raised_at`, `:inserted_at`). `raised_at` is the better signal
  for context — an in-place update bumps `updated_at` without a new run.
- **`:summary_limit` on `project_finding/2`/`project_for_context/2`**, bounding
  `summary` length (default 500 graphemes) so context does not grow without
  bound.

### Fixed
- **Context assembly no longer hides load failures.** The templates' bare
  `rescue _ -> []` reported DB timeouts, missing columns, and encoding bugs as
  "no findings" — indistinguishable from an actor that genuinely has none.
  Failures are now logged with the actor/episode id, and the assembled context
  carries a `findings_loaded` flag so a strategy can tell "loaded, empty" from
  "failed to load".

## [0.3.4] — 2026-07-24

### Fixed
- **Episodes no longer crash once an actor has active findings.** Both the
  `AgenticTask` and `Interactive` templates seeded their context-assembly
  observation with raw `%Cyclium.Schemas.Finding{}` Ecto structs, which are not
  `Jason.Encoder`-able. As soon as an actor had any active finding, the journal
  insert (JSON-encoded for SQL Server) crashed every subsequent episode —
  agentic runs *and* every interactive chat turn — at step one. Findings are now
  projected to compact, JSON-safe maps via `Cyclium.Findings.project_for_context/1`
  (also drops multi-KB `evidence_refs` narratives from the first prompt).
- **Conversation dispatch no longer requires strategy module equality.**
  `Conversations.Dispatch` matched the registered strategy against the literal
  `Template.Interactive` module, so an app wrapping the template (the sanitizer
  workaround) had every chat turn rejected with `:not_interactive_expectation`.
  Dispatch now accepts the stock template or any strategy that opts in with an
  `interactive?/0` callback returning `true`.
- **Manual triggers now carry `force_fire`'s payload.** `%Trigger.Manual{}`
  gained a `payload` field, and `AgenticTask.trigger_payload/1` reads it, so
  objective `{{placeholders}}` and payload-scoped strategy logic work for
  manually fired agentic runs.
- **Agentic `strategy_config` resolves by `{actor, expectation}`.**
  `Loop.load_strategy_config/2` resolves the exact expectation's config instead
  of first-match-by-actor, which was nondeterministically wrong for any actor
  with more than one expectation.
- **Defense in depth:** the journal's size guard (`cap_stored_map/1`) now
  degrades a non-JSON-encodable step payload to a preview marker instead of
  letting the encode failure default to "size 0, pass through" and crash the
  insert.

## [0.3.3] — 2026-07-23

### Changed
- Successfully completed episodes now **delete their checkpoints** (both the
  `:done` step-action path and the post-converge `:episode_completed` path).
  Checkpoints exist only to resume in-flight work; a completed episode can
  never resume, so its rows were dead storage. Failed and blocked episodes
  keep their checkpoints — a re-enqueue with `resume: true` (recovery sweep or
  manual) resumes from the latest one. Cleanup is best-effort and never fails
  a finished episode.

## [0.3.2] — 2026-07-23

### Added
- Checkpoint schemas can now be declared directly on the expectation
  (`checkpoint_schema: MyApp.Checkpoints.ResourceCheck`), alongside `strategy`.
  The actor registers the mapping in persistent_term at boot — no app config
  needed. `config :cyclium, :checkpoint_schemas` still works and takes
  precedence over the expectation declaration, so it doubles as a deploy-time
  override. Resolution is centralized in `Cyclium.CheckpointSchema.resolve/2`,
  used by both the checkpoint write path (version stamping) and the restore
  path (migration), so the two can no longer disagree on which schema applies.

## [0.3.1] — 2026-07-22

### Fixed
- Recovery now **resumes** restarted episodes from their latest checkpoint.
  Both `Recovery.sweep`'s direct runner path and the actor hand-off
  (`{:recover_episode, id}` → `enqueue_recovered`, including episodes parked in
  the actor's overflow queue and drained later) previously enqueued without
  `resume: true`, so a recovered episode re-ran `init/2` from the trigger and
  replayed every completed step — checkpoints were effectively ignored on the
  recovery path (only `Runner.OTP.recover_incomplete/0` resumed correctly).
- `save_checkpoint` no longer hardcodes `schema_version: 1`. It stamps the
  version the registered `Cyclium.CheckpointSchema` currently writes (resolved
  from `config :cyclium, :checkpoint_schemas` with the same
  `{actor_id, expectation_id}` → `actor_id` lookup the restore path uses), so
  `migrate_to_current/2` sees the true on-disk version and schema migrations
  can actually fire. Unregistered actors keep writing version 1.

## [0.3.0] — 2026-07-16

### Added
- **`Cyclium.Strategy.Template.AgenticTask`** — an autonomous, tool-calling
  strategy template. It runs the same interpret → validate → execute →
  summarize loop as the interactive template, but with no human in the loop:
  the run is seeded from an **objective** (a static `strategy_config` template
  interpolated with `{{key}}` / `{{a.b}}` placeholders from the trigger payload,
  or an objective supplied on the payload itself), fires from
  `Event`/`Schedule`/`Manual`/`Workflow` triggers, and lets the LLM call tools
  as it sees fit (bounded by `allowed_tool_signatures`). It converges to
  findings and/or outputs. Registered as the `"agentic_task"` template.
- A reserved **`finish_agentic_task`** tool, auto-injected into the AgenticTask
  tool menu, gives the model an explicit terminal action. Calling it ends the
  run and its args (`summary`, `confidence`, `findings`, `outputs`) become the
  converge result. It is intercepted before `PlanGate`/`ToolExec` — there is no
  real capability to register — and is never offered by the interactive
  template. A plain-text (`explain_only`) answer is also accepted as a terminal.

### Changed
- The shared interpret → validate → preview → execute → summarize loop was
  extracted from `Cyclium.Strategy.Template.Interactive` into
  `Cyclium.Strategy.Template.Agentic.Loop`. Both the interactive and
  `AgenticTask` templates delegate to it; each supplies only its own `init/2`,
  `:context_assembly` phase, and `converge/2`. Interactive behavior is
  unchanged (its full test suite passes as-is).
- `TemplateRegistry` now also registers the previously-unlisted `"interactive"`
  template alongside the new `"agentic_task"`.

## [0.2.2] — 2026-06-22

### Fixed
- The journaled `:map` cap (0.2.1) crashed on values that are structs — e.g. a
  `DateTime` in a `result_ref` — because a struct is a map but isn't
  `Enumerable`, so truncating its "leaves" raised `protocol Enumerable not
  implemented for DateTime`. Structs are now treated as leaf values (kept as-is)
  rather than recursed into.

## [0.2.1] — 2026-06-22

### Fixed
- Native tool schemas no longer force every argument to `type: "string"`. The
  hint is carried as the property `description` with the type left open, so the
  model can pass structured arguments (an array of `rows`, a `headers` list)
  instead of stringifying them — which had made structured-arg tools fail (e.g.
  `generate_csv` → `no_rows`).
- The summarize phase now loops back to execute a follow-up `:multi_tool_plan`,
  not just a single `:tool_call`. Native mode emits a multi_tool_plan whenever
  the model calls several tools at once on a follow-up turn; previously that fell
  through and the whole envelope was JSON-encoded into the reply (a raw
  `multi_tool_plan` blob shown as the assistant's answer).
- Journaled step `:map` fields (`result_ref`, `args_redacted`, `error_detail`)
  are capped below the Tds nvarchar parameter boundary (~4000 bytes / ~2000
  chars). Past it, SQL Server silently truncated the value before it reached the
  nvarchar(max) column, so it failed to JSON-decode on read and crashed every
  reader of the row (the runner's post-converge and the chat transcript). The
  full reply still lives on `episode.summary`; the step `:map` fields are
  supplementary, so truncating them is safe.

## [0.2.0] — 2026-06-22

### Changed
- Native (structured) tool calling is now the **default** for the interactive
  template (was opt-in in 0.1.15). The synthesizer uses the native path whenever
  the configured client implements `chat_with_native_tools/4`; an actor opts out
  with `strategy_config: %{tool_mode: :text}`, and a client that lacks the
  callback falls back to the text path automatically.

### Fixed
- In native mode the system prompt and user message now omit the text-envelope
  instructions and the prose tool list. Previously they still told the model to
  emit a JSON `ActionPlan` envelope, so it returned the envelope as text instead
  of calling the structured tools (which then surfaced as an `explain_only` whose
  explanation was the raw envelope JSON).

## [0.1.15] — 2026-06-17

### Added
- Opt-in **native (structured) tool calling** for the interactive template. Set
  `strategy_config: %{tool_mode: :native}` and, when the configured LLM client
  implements the new optional `chat_with_native_tools/4` callback, the synthesizer
  passes the actor's tool signatures to the provider as structured `tools` and
  reads back validated `tool_use` blocks instead of parsing a JSON `ActionPlan`
  envelope out of free text — removing the whole class of text-parse failures
  (smart quotes, dotted names, over-structured values). The structured result is
  shaped back into the same envelope map, so the ActionPlan/validate/approve/
  execute machinery (and approval gates, trace cards, `plan_hash`) is unchanged.
  Each (tool, action) maps to one flat native tool named `"<tool>__<action>"`,
  split back on return. Default remains `:text`.
- `Cyclium.Tool` gains an optional `tool_signature/0` callback (defaults to `nil`
  via `use Cyclium.Tool`) so tools can self-describe in `allowed_tool_signatures`
  shape and actors can introspect them generically — opt-in, no existing tool is
  forced to declare one.
- Per-expectation `render_log` option (default `true`). Set `render_log: false`
  on an expectation to skip rendered-log materialization (`Cyclium.LogProjector`)
  while keeping full step journaling — useful for interactive actors whose chat
  UI reads the step timeline directly and never needs the projected log. The
  episode runner gates the per-step projection on this flag; existing
  expectations are unaffected.
- Per-expectation `render_log_strategy` option. When set, it controls the
  **rendered log's verbosity** (`:none` / `:summary_only` / `:timeline` /
  `:full_debug`) independently of `log_strategy`, which continues to drive what
  step data is *journaled*. So an actor can journal full step data for a chat UI
  but render only a summary (or the reverse). Unset falls back to `log_strategy`,
  so existing expectations are unchanged. `Cyclium.LogProjector` resolves the
  override from persistent_term at render time.
- Open `metadata` (`:map`) bag on `cyclium_episodes` **and**
  `cyclium_episode_steps` (migration V25). The episode bag records the
  **primary** model the run used (e.g. `%{"model" => "..."}`), stamped once on
  the first synthesis that reports one; a step records a model only when it
  *diverges* from that primary, so a single-model episode doesn't repeat the
  model on every step. The interactive synthesizer now tags its result with the
  configured model (also populating the `model` on `[:cyclium, :step,
  :synthesis]` telemetry). `Cyclium.Episodes.merge_metadata/2` shallow-merges
  into the bag. Nullable, additive, backwards-compatible. (Capturing the
  adapter-*default* model and real token usage needs a richer LLM return — see
  the native tool-calling work.)

### Fixed
- `conversation_id` is now included on the episode/workflow lifecycle **Bus**
  events that previously omitted it (`episode.started`, `episode.failed`,
  `episode.completed`, `episode.canceled`, `episode.queued`, `episode.dropped`,
  `expectation.triggered`, `episode.step_journaled`, `finding.*`,
  `output.delivered`, and `workflow.started/step_started/completed/failed`).
  Previously only the telemetry events carried it, so Bus subscribers couldn't
  correlate these events to a conversation. It's `nil` for non-conversational
  runs (matching the telemetry events). (The shed-path `episode.canceled` in the
  actor overflow handler still omits it — only the queued id is in scope there.)
- Interactive template envelope parsing hardened against model-behavior quirks
  (surfaced by gpt-5-family models on the text-JSON `ActionPlan` protocol):
  - `Cyclium.Synthesizer.Interactive.extract_json/1` now **decodes first and
    only normalizes quotes as a fallback**, so a valid payload whose string
    *values* legitimately contain smart/curly quotes (e.g. inside an
    `explanation`) is no longer corrupted into a parse failure that leaks the
    raw envelope to the user.
  - `Cyclium.Strategy.Template.Interactive` splits a **dotted tool name**
    (`"episode_query.list_episodes"` with a blank `action`) into tool + action
    at parse time, so it matches an allowed signature instead of being denied.
  - A non-string `explanation` (a model over-structuring its answer as a nested
    object/array) is now **coerced to text** rather than leaking an inspected
    blob; `nil` is preserved so the explanation-fallback chain still works.
- Step journaling no longer crashes an episode on a transient DB-layer fault
  (an intermittent `Tds.Error` / `DBConnection.ConnectionError` on a single
  INSERT). Such a write now **degrades gracefully**: it's logged at `error`,
  emits a `[:cyclium, :step, :journal_dropped]` metric so a spike is visible,
  and the episode continues with an in-memory step struct — only that one
  journal row + its rendered-log/bus projection is lost. Non-transient errors
  (a real schema/encoding bug) still raise so they aren't masked.

## [0.1.14] — 2026-06-15

### Fixed
- Interactive synthesizer no longer leaks raw JSON (and silently skips tool
  calls) when the model emits the response envelope with smart/curly quotes or
  wraps it in prose / multiple objects. `parse_json_response` now normalizes
  curly quotes to straight and extracts the first balanced `{...}` object before
  `Jason.decode`, so the envelope parses, the tool call executes, and the
  summary is clean prose.

### Added
- Per-actor LLM options. Synthesizer opts beyond `:llm` (e.g. `model:`,
  `max_tokens:`) declared as `synthesizer({Cyclium.Synthesizer.Interactive, llm:
  Adapter, model: "..."})` are kept in `persistent_term` and forwarded to the
  LLM client's `chat/3` opts — so an actor can pick a model without a bespoke
  adapter. Falls back to `config :cyclium, :interactive_llm_opts`.
- `Cyclium.Exports.create/1` size guard: content larger than
  `:export_max_bytes` (default 5 MB) is rejected with `{:error, :too_large}`,
  guarding the inline-content table against runaway exports.

### Telemetry
- Emit `[:cyclium, :episode, :blocked]` (with `episode_id`/`actor_id`/
  `conversation_id` and `reason: :approval | :wait`) when an episode parks on an
  approval or external wait — previously declared but never fired.
  (Note: `finding.*` and `output.*` events *are* emitted, via dynamic atoms in
  `Findings`/`Output.Router` — they only looked unfired to a literal source scan.)
- Trimmed declared-but-never-emitted events from `@events` and the moduledoc, so
  consumers don't build against a phantom contract: `episode.queued`,
  `budget.tokens`, `budget.turns`, `step.output`, `phase.changed`, and
  `guardrail.triggered` (guardrails are not implemented). Confirmed none are
  emitted via a dynamic atom before removing.

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

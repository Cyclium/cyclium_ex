# Changelog

All notable changes to Cyclium are recorded here. This project uses
[Semantic Versioning](https://semver.org/).

Entries are high-level, not exhaustive. Versions prior to `0.1.4` are
reconstructed from git history and are summarized loosely.

## [0.6.0] — 2026-10-28

### Added
- **Interactive turns carry the conversation's history.** The interactive
  template loads the conversation's most recent finished turns — each user
  `message`, its reply, and the names of the tools it called — and the
  synthesizer renders them as alternating `User:` / `Assistant:` lines under
  `## Conversation History`, in the interpret prompt and in the prompt after a
  tool runs (text and native paths). `strategy_config` `history_turns` caps the
  turns sent (default 20, newest kept; `0` sends none). The assembled context
  carries them as `history` (`%{role, content}` entries); `prior_summaries` is
  still assembled. A trigger that sets `Trigger.Interactive.history` supplies
  the history instead.
- **`episode.step_started`** is broadcast on the Bus as a tool call or LLM
  request goes out, before the runner waits on it, with `episode_id`,
  `actor_id`, `expectation_id`, `conversation_id`, `kind` (`:synthesis` or
  `:tool_call`), `tool_name` and `started_at`.
- **`[:cyclium, :step, :synthesis, :start]`** telemetry fires as an LLM request
  goes out.
- **Scoped Bus topics.** Every event also goes to a topic for each id its
  payload names, so a view can subscribe to one run, conversation, actor or
  workflow instance: `Cyclium.Bus.subscribe(episode: id)`,
  `subscribe(conversation: id)`, `subscribe(actor: id)`,
  `subscribe(workflow: id)`. Messages keep the `{:bus, event_type, payload}`
  shape. `Cyclium.Bus.unsubscribe/1` takes an event type or a scope.
- **Tool-result cache.** `ToolExec` now honours `Cyclium.Tool`'s `cache_ttl/0`
  and `cache_scope/1`: a tool that declares a TTL (in seconds) has its
  successful results reused within the conversation, or the episode outside a
  conversation, for that long. Errors are never cached, nor is any tool whose
  `side_effect?/0` is true. A reused result is still journaled as a tool call,
  with `metadata: %{"cache_hit" => true}`. Entries are dropped when a
  conversation resolves, is abandoned or times out, and swept once expired, by
  the new `Cyclium.ToolCache` process under `Cyclium.Supervisor`. The cache is
  per node. `[:cyclium, :tool_cache, :hit]` / `:miss` telemetry report lookups.
- **`Cyclium.Synthesizer.Interactive.validate_tool_signatures/1`** checks native
  tool names (`^[a-zA-Z0-9_-]{1,64}$` for `"<tool>__<action>"`) and argument
  names (`^[a-zA-Z0-9_.-]{1,64}$`).

### Changed
- **A synthesis step records `cost_ms`**, the LLM call's duration, on success
  and on error, as tool-call steps do. A step's start is `created_at − cost_ms`
  for both kinds.
- **The provider's token usage is recorded on every path.** The native path
  keeps the `usage` that `chat_with_native_tools/4` returns, and `chat/3` may
  now return `{:ok, %{text: text, usage: usage, model: model}}` (a bare
  `{:ok, text}` still works). Cached input (`cache_creation_input_tokens`,
  `cache_read_input_tokens`) counts toward an episode's `tokens_used`, a step's
  `cost_tokens` and the synthesis event's `total_tokens`, which also gains the
  two cache measurements.
- **`estimate_tokens/1` counts what is sent**: the system prompt, the user
  message as built (history, findings, collected fields, tool results) and the
  tool schemas. It is only used when a provider reports no usage.
- **An actor fails to start when a tool or argument name breaks the native
  limits**, raising `ArgumentError` naming each bad one. Expectations with
  `tool_mode: :text` are not checked.
- **Actors subscribe to what they act on**, not the whole bus: the event types
  their expectations listen for, plus `episode.completed`, `episode.failed` and
  `episode.canceled`. A reconcile moves the subscriptions with the
  expectations. Per-step events from other runs no longer reach every actor.
- **`Cyclium.Bus.publish/2` delivers as `broadcast/2` does**: to the event
  type's topic and the scoped topics as well as the global topic.
- `episode.dropped` no longer carries a `conversation_id` key; it was always
  `nil`, since conversation turns skip the capacity check.
- `Cyclium.Tool`'s default `cache_scope/1` keys on the call's args (without
  `_`-prefixed internal keys) instead of `""`.

### Upgrade notes
- Rename any tool, action or argument whose name breaks the limits above, or
  set `tool_mode: :text` on that expectation.
- Read `payload[:conversation_id]` rather than matching it on `episode.dropped`.
- Send domain events with `Cyclium.Bus.publish/2` or `broadcast/2`. An event
  sent with `Phoenix.PubSub` straight to the `"cyclium:events"` topic no longer
  reaches actors, which listen on event-type topics.
- A process subscribed to both the global topic and an event type's topic now
  receives a `publish/2`ed event twice, as it already did for `broadcast/2`.
- A LiveView can drop its `Cyclium.Bus.subscribe()` for
  `subscribe(conversation: id)`, `subscribe(episode: id)` or
  `subscribe(actor: id)`.
- `total_tokens` in `[:cyclium, :step, :synthesis]` now includes cached input;
  dashboards built on it will read higher for prompt-cached calls.
- An interactive prompt grows with the conversation; lower `history_turns` for
  actors with long turns or tight `max_tokens` budgets.

## [0.5.2] — 2026-10-21

### Security
- **The plan gate checks the action, not just the tool.** `allowed_tool_signatures`
  entries now carry their `actions`, and `Cyclium.Intent.SignatureMatcher` denies
  a step whose action the signature does not list. A signature with no actions
  allows none; `"actions" => "*"` opts a tool into every action deliberately. An
  action entry may declare its own `side_effect`, so a read tool with one write
  action previews only the write. Previously a model could reach any `call/3`
  clause of an allowed tool, including actions withheld from that actor.
- **An approved plan is re-validated on resume.** `resume_from_block/2` re-enters
  `:validate` (skipping only the second preview) instead of jumping to
  `:execute`, and a `:request_approval` plan's journal entry is nested under
  `"request"` with `source: "request_approval"`, so a model-authored approval
  request can never be rebuilt into an executed plan. `Episodes.resolve_approval`
  refuses a step with no stored `plan_hash` (`{:error, :no_plan_hash}`) and
  accepts a `:principal` option that must match the conversation's principal.
- **Outputs and workflow triggers are gated.** An `:output_proposal` must use a
  type in `allowed_output_types` and a `:workflow_trigger` a workflow in
  `allowed_workflows`; absent lists allow none. `OutputProposal.requires_approval`
  now forces a preview. `Cyclium.Strategy.Template.Interactive` defaults
  `require_preview_for_side_effects` to `true`.
- **Model-authored findings are normalised.** `Loop.build_findings_list/1` keeps
  only content fields under atom keys, maps `severity` onto the finding enum,
  and drops identity/lifecycle fields (`actor_id`, `env`, `status`, …); a finding
  always persists under the episode's actor and env. One malformed finding counts
  as a failed persist instead of crashing post-converge.
- **No atoms are minted from model output.** Output types stay strings, tool and
  action names resolve through existing atoms only (a name with no atom is
  denied), severities map onto the enum, dynamic actors register under
  `{:cyclium_dynamic, actor_id}` tuples, and definition JSON decodes with
  `Cyclium.AtomGuard.key/1`. `AtomGuard.usage/0` and a
  `[:cyclium, :atom_guard, :refused]` event expose table pressure.
- **Modules come from code, not from strings.** `plan_policy` must be a module
  atom in the expectation's `strategy_config` and must be a loaded
  `Cyclium.Intent.PlanPolicy` (otherwise the plan is denied; a policy that raises
  denies too). A custom goal evaluator is declared on the expectation with
  `goal_evaluator: MyModule`; a module name in a goal's JSON is never resolved.
  A dynamic expectation's `strategy` must name a registered template.
  `Cyclium.StrategyConfig` only reads a definition row for actors the dynamic
  loader started, so a row named after a compiled actor cannot supply its config.
- **Conversations are checked against their principal.**
  `Conversations.get_for_principal/3`, `principal_matches?/2`;
  `LiveHelpers.load_or_create_conversation/5` returns `{:error, :forbidden}` for
  another principal's conversation; `Dispatch.send_message/3` refuses a
  mismatched `:principal` (claiming an unowned conversation for it) and takes
  `system: true` for trusted callers.
- Smaller hardening: a budget of `0` is exhausted, not unlimited; `capabilities`
  declared in the Actor DSL are enforced by `ToolExec`; `Cyclium.Redaction`
  strips credential-like keys from journaled tool args/results and output
  payloads (adapters may add `redact/1`); lifecycle broadcasts carry
  `Cyclium.Bus.public_trigger_ref/1` (no `message`, `principal` or `history`);
  the Reconciler ignores a `spec.updated` whose module is not an actor; the
  workflow engine checks that a terminal event's episode row belongs to the
  instance and step it names; `PlanGate` reports structural errors as
  `{:deny, _}`; conversation JSON columns decode tolerantly; subject keys for
  JSON-path queries must be identifiers; `stream_data` is test-only.

### Upgrade notes
- Add `actions` to every `allowed_tool_signatures` entry (or `"actions" => "*"`).
- Add `allowed_output_types` / `allowed_workflows` to actors that propose outputs
  or start workflows.
- Model-proposed `OutputProposal.type` is a string; `Loader.process_name/1` is a
  tuple; `LiveHelpers.load_or_create_conversation` may return `{:error, _}`.

## [0.5.1] — 2026-10-21

### Fixed
- **Every run-ending Bus event now names the run's subject.** 0.5.0 added
  `expectation_id` and `trigger_ref` to `episode.completed`, `episode.failed`
  and `episode.canceled`, but only where the runner and `Episodes.cancel` send
  them. Five other paths still sent neither, so `Cyclium.Bus.subject/2` read
  `nil` and a subscriber matching on the subject missed the run's end:
  `episode.failed` from `Cyclium.EpisodeTask` when the task crashes
  (`error_class: "crash"`) or exits mid-run (`"process_terminated"`);
  `episode.failed` from `Cyclium.Recovery` failing an orphan (`"orphaned"`);
  the `episode.completed` / `failed` / `canceled` that `Recovery` replays for a
  stale workflow step; and `episode.canceled` when an actor with
  `episode_overflow(:shed_oldest)` sheds its oldest queued run. All five now
  carry `expectation_id`, `trigger_ref` and `conversation_id`. The shed event
  also gains `status: :canceled`, and is no longer sent when the cancel fails
  to save.

### Docs
- **`Cyclium.Bus` says how payloads are keyed.** Runtime event payloads are
  atom-keyed maps, delivered unchanged across nodes, so match
  `payload[:actor_id]`; only the inside of `trigger_ref` (the episode's stored
  JSON) is string-keyed, which `subject/2` reads.

## [0.5.0] — 2026-10-19

### Changed
- **Run-ending Bus events now name the run's subject.** `episode.completed`,
  `episode.failed`, `episode.canceled` and `episode.interrupted` carry
  `expectation_id` and `trigger_ref` — the same subject fields `episode.started`
  already sends — so a subscriber can tell which run finished without its own
  `episode_id` bookkeeping or a DB read. `episode.queued` gains `trigger_ref`
  too, so a page can show a run as waiting before it starts. The episode is
  already in hand at each broadcast site, so the fields are additive and cost no
  extra read.

### Added
- **`Cyclium.Bus.subject/2`** reads `trigger_ref["payload"][key]` from an event
  payload, so subscribers stop hand-rolling the nested access. Returns `nil`
  when any level is missing.

## [0.4.4] — 2026-09-21

### Changed
- **A graceful shutdown no longer fails the episode it interrupts.** A `:shutdown`
  (or `{:shutdown, _}`) EXIT reaching the runner between steps used to journal
  `episode_failed` and set the row `:failed` with `error_class: "process_terminated"`.
  That put the episode out of `Cyclium.Recovery.sweep/1`'s reach — the sweep lists
  `:running` rows only — so an expectation's `recovery_policy: :restart` never
  applied to the most common way a run is cut off: a deploy. The runner now leaves
  the row `:running`, sets `phase: "interrupted"`, releases the work claim
  (`gate_fail`, so the recovering node can re-acquire it at once) and broadcasts a
  new `episode.interrupted` Bus event. `Cyclium.EpisodeTask` skips its
  "still running at exit → failed" safety net for that case. Other abnormal EXITs
  still fail the episode as before.
- **`Episodes.list_stale_running/2` returns interrupted episodes regardless of
  recency.** The node that had the episode has already said it is not coming back
  to it, so the staleness window only delayed the restart.
- **Recovery restarts are bounded by the episode's `max_attempts`.** Every
  recovery claim increments `attempts`; once it exceeds `max_attempts` (default 3)
  a `:restart` policy fails the episode as `orphaned` with an "attempts exhausted"
  reason instead of restarting it. Without the cap a rolling deploy could bounce an
  episode between nodes indefinitely — a node still up sweeps and restarts it, is
  drained itself and hands it back interrupted, and the next survivor repeats.

### Fixed
- **A `:restart` recovery never actually restarted a claimed episode.** The sweep
  holds a "recovery" work-claim lease on the episode's `dedupe_key` from its
  optimistic claim, and `EctoClaims.acquire/3` treats an active lease as busy for
  every caller including its own owner — so the `EpisodeTask` the sweep enqueued
  got `{:error, :busy}`, exited normally, and never ran. The episode sat
  `:running` with nothing journaled until the next sweep found it stale and did
  the same thing again, burning an attempt each time until it failed as
  exhausted. Every interactive episode has a dedupe key, so every chat reply a
  restart interrupted was lost this way. The sweep now completes its recovery
  lease before enqueueing (the task re-acquires the `:done` slot at once) and
  fails it when it fails the orphan.

### Added
- **`Cyclium.EpisodeDrainer` hands a node's running episodes to recovery in bulk on
  shutdown.** It sits after `Cyclium.EpisodeSupervisor` in `Cyclium.Supervisor`, so
  it is stopped first, and its `terminate/2` reads the running tasks off the new
  `Cyclium.EpisodeProcessRegistry` (each `EpisodeTask` registers once it holds its
  claim) and issues three statements for all of them — the `interrupted` phase
  stamp, the claim release, and one `:observation` journal marker per episode
  (`%{"event" => "interrupted"}`) — then broadcasts `episode.step_journaled` /
  `episode.interrupted` per episode and sends each task `:cyclium_drained`, which
  the runner takes at its next step boundary as "stop, write nothing". Tasks
  killed mid-step were already stamped. A shutdown with a dozen episodes in
  flight is three writes, not thirty-six contending for a draining pool, and each
  statement is best-effort so a failed marker insert cannot cost the phase stamp.
  The runner's own shutdown path now goes through `EpisodeDrainer.interrupt/1`
  for the single-episode case.
- **`Cyclium.Episodes.journal_marker/3`** appends a lifecycle step from outside
  the loop. Recovery uses it twice: an `:observation` `%{"event" => "resumed",
  "attempt" => n, "node" => ...}` on a restart, so a step feed reads
  interrupted → resumed → fresh start rather than a run that silently began
  again; and an `:episode_failed` step (`error_class: "orphaned"`) when it fails
  an orphan, so a `:fail`-policy run's journal ends on the verdict rather than on
  the drainer's "interrupted" marker.
- **`config :cyclium, :episode_shutdown_ms`** — the supervisor shutdown timeout
  for `Cyclium.EpisodeTask` (default unchanged at `Task`'s 5 seconds). A step is
  typically one LLM call, so a longer window lets it finish and take the graceful
  path above instead of being killed mid-step and recovered only once stale.

## [0.4.3] — 2026-09-17

### Added
- **Span-shaped telemetry around self-scheduled background work, so a host
  application can nest a worker's queries under a single trace.** Several of
  Cyclium's workers run on their own timer or as a detached startup task — the
  trigger-request poller, the recovery sweep and workflow reconciliation, the
  finding sweep, and the work-claims heartbeat. None run under a caller, so a
  host that traces its database work (e.g. via `opentelemetry_ecto`, which
  parents each query span to the calling process's context) has nothing to parent
  their queries to: every query opens its own root trace, with nothing tying one
  tick's queries together or recording how long the tick took. A point-in-time
  telemetry count cannot hold a span open across the work that follows it, so
  each worker now wraps its tick in `:telemetry.span/3` via the new
  `Cyclium.Telemetry.span/3`, emitting a `:start`/`:stop` (or `:exception`) pair
  under one shared event prefix:
  - `[:cyclium, :background_work, :start | :stop | :exception]`, tagged with the
    worker in `metadata.work` (`:trigger_requests_poll`, `:recovery_sweep`,
    `:recovery_reconcile`, `:finding_sweep`, `:work_claims_heartbeat`). The scope
    tags (`:node`, and `:source_stack`/`:source_env` where the worker is scoped)
    ride on all three events, and `:stop` carries a small `:result` map of
    low-cardinality counts summarising the tick.
  - These are a different *kind* of event from the point-in-time signals, so they
    are deliberately **not** in `events/0` (a logging consumer is unaffected) and
    are listed separately by the new `Cyclium.Telemetry.span_events/0` (a tracing
    consumer attaches to exactly these). The workers' existing point-in-time
    events (e.g. `[:cyclium, :finding_sweep, :completed]`,
    `[:cyclium, :recovery, :sweep]`) are unchanged.

### Changed
- **`[:cyclium, :actor, :event_received]` now fires only when the event is
  relevant to the actor.** Every actor is subscribed to the whole bus, so a
  single lifecycle broadcast (e.g. `episode.completed`) was delivered to — and
  emitted a `:event_received` telemetry point from — *every* actor, fanning one
  event out into N points (and, for any logging consumer, N log lines) even
  though most actors immediately dropped it. The event now fires only when one of
  the actor's expectations subscribes to it, or it is a lifecycle transition of
  the actor's *own* episode (the cases where the actor actually acts on it).
  `episode.step_journaled` remains filtered as before. No change to which
  episodes fire or how lifecycle slots are freed — only to when the telemetry is
  emitted.

## [0.4.2] — 2026-09-03

### Fixed
- **A failed summarize-phase synthesis now fails the episode instead of being
  recorded as a completed `no_action`.** In the shared agentic loop
  (`Cyclium.Strategy.Template.Agentic.Loop`) the summarize-phase error clause had
  no retry and no explanation — it set `phase: :done` and let `converge/2` fall
  through to `no_action`, so an infrastructure failure (e.g. an `overloaded_error`
  / HTTP 529 from the model) surfaced as a business outcome: the episode ended
  `done`, `episode.failed` never fired, and monitoring could not tell it apart
  from a genuine no-finding run. The clause now:
  - retries the synthesis (3 attempts, 2s → 4s backoff — matching the interpret
    phase, which already retried), then
  - aborts with `{:synthesis_error, error_class, detail}` so
    `EpisodeRunner.abort_episode/2` records error_class `synthesis_error:<class>`,
    marks the episode `failed`, journals `episode_failed`, and broadcasts
    `episode.failed`.
  - The abort `detail` carries `completed_tool_steps`, so a trace reader sees the
    tool data was gathered and only the interpretation call was lost.
  `no_action` is preserved for its real meaning — the model concluded there was
  nothing to do — and is no longer produced by a synthesis error.
- **`Cyclium.Strategy.Retry.check/3`'s `:backoff_ms` accepts a 1-arity function**
  of the upcoming (1-based) attempt number, so callers can escalate backoff per
  attempt (e.g. `fn n -> 2_000 * n end`). A plain integer still works.

## [0.4.1] — 2026-09-01

### Changed
- **Compiler warning cleanup — no behavioral change.** Removed dead clauses and
  redundant code the Elixir 1.18 type checker flagged as unreachable, so the tree
  compiles clean under `--warnings-as-errors`:
  - `Cyclium.Intent.PlanValidator.validate_fields/2` — dropped the catch-all;
    `validate_kind/1` already constrains `kind` to the handled set.
  - `Cyclium.Log` — dropped the unused `require Logger` (only `Logger.metadata/1`,
    a function, is called).
  - `Cyclium.LogProjector` — dropped the unreachable `max_step_no([])` clause (its
    caller is guarded by `if steps == []`) and the dead `else` on
    `render_log_strategy_override/1`'s `with`.
  - `Cyclium.Mode.safe_to_atom/1` — dropped the atom-clause; the sole caller
    guards with `is_binary/1`.
  - `Cyclium.EpisodeRunner.render_log?/1` — dropped the dead `else` and the
    unreachable catch-all clause.
  - `Cyclium.Strategy.Retry.step_key/1` — the map-without-`:kind` clause now
    returns `:unknown` directly instead of a `Map.get/3` that always did.

## [0.4.0] — 2026-08-24

### Fixed
- **`cyclium_conversations` JSON columns widened to `nvarchar(max)` (migration
  `V26`).** `goal`, `origin`, `audience_target`, `result` and `collected_fields`
  are all written as `Jason.encode!` output but `V15` created them as bare
  `:string` — `nvarchar(255)` under TDS. Any real JSON payload (a filtered page
  context is ~300 chars) overflows and SQL Server raises 8152, which surfaces as
  a *raise* from `Repo.update` rather than a changeset error, killing the caller.
  `V26` `modify`s the five columns to `size: :max`, matching the `nvarchar(max)`
  the episode tables already use for JSON of unknown size. `principal` is
  deliberately excluded — a host app may define PERSISTED computed columns over
  it, and SQL Server refuses to alter a column a computed column references.
- **`Cyclium.Conversations.update_collected_fields/2` honours its
  `{:ok, _} | {:error, _}` contract for driver-level failures too**, not just
  changeset ones. `Repo.update/1` raises on a raw adapter error (Ecto doesn't
  wrap those), so a caller that only handled `{:error, _}` was still killed. The
  update now rescues, logs loudly, and returns `{:error, exception}`.

### Added
- **`Cyclium.CheckpointSchema.json_plain?/1` and `assert_json_plain!/1`.** A
  checkpoint's state is persisted through a JSON round-trip; values that *encode*
  but don't *round-trip* (atom keys/values → strings, tuples/structs failing
  outright) come back subtly wrong on resume because `init/2` is not re-run.
  These helpers let a strategy's checkpoint test assert the JSON-plain constraint
  at the source instead of discovering it after a bad resume.
- **`[:cyclium, :checkpoint, :save_failed]` telemetry.** `save_checkpoint`
  already logged loudly and continued when state couldn't be persisted; it now
  also emits telemetry (with `actor_id`, `expectation_id`, `phase`,
  `error_class`) so a dropped checkpoint is observable/alertable, not just
  log-visible. A spike means resume is silently falling back to a fresh init.
- **`usage_reported` in `[:cyclium, :step, :synthesis]` telemetry metadata**, and
  a warning when a synthesis result that names a model omits its `usage` key. A
  missing `usage` read as zero tokens everywhere downstream (budgets, cost
  accounting), indistinguishable from a genuinely free synthesis; the omission is
  now visible rather than silently undercounted.

## [0.3.7] — 2026-08-14

### Fixed
- **`:full_debug`/`:timeline` step logging no longer crashes on synthesis args
  containing structs.** `redact_synthesis_args/1` (and `summarize_result/1`)
  guarded on `is_map/1`, which is also true for structs, then walked the value
  with `Enum.reduce`. A synthesis payload holding a struct such as
  `Cyclium.Intent.GoalSpec` therefore raised `protocol Enumerable not
  implemented for Cyclium.Intent.GoalSpec` on every turn. Both the top-level
  clauses and the nested recursion now guard on `is_map(x) and not
  is_struct(x)`, so structs pass through untouched while plain-map redaction and
  summarization are unchanged.

### Changed
- **Stored step `:map` cap raised from 1,800 to 1,000,000 chars.** The old cap
  was justified by a supposed "~4000-byte Tds nvarchar truncation"; that was a
  misdiagnosis — the `args_redacted` / `result_ref` / `error_detail` columns are
  `nvarchar(max)` and Tds 2.3.x PLP-chunks any oversized nvarchar parameter, so
  large JSON round-trips intact (verified against `Tds.Types.encode_data/3`).
  The 1,800 cap was silently truncating approval-plan args — breaking
  `resume_from_block` / `latest_approval` into an infinite re-plan loop — and
  large tool payloads in rebuilt transcripts. The cap is now purely a runaway
  guard against pathological multi-MB blobs (readers JSON-decode these rows into
  memory); every realistic payload now survives journaling. Fully lossless
  storage for the pathological case (chunk-and-reassemble / out-of-row blob)
  remains future work.

### Removed
- **Dropped the unused `:plan_preview` step kind** from the `EpisodeStep` enum.
  It had no producer or consumer anywhere in the runtime and was omitted from
  the documented kind list; removing it leaves 16 kinds. The `kind` column is a
  plain string, so no migration is required.

### Documentation
- **`Cyclium.Tool.side_effect?/0` documented as advisory.** Added a `@doc`
  clarifying that this callback does **not** drive the approval gate — gating is
  decided by the strategy's `allowed_tool_signatures` `side_effect` class — so
  setting `side_effect?/0 => true` alone will not gate a write tool.
- **Added an "Outputs vs tool calls" section** to `guides/findings_and_outputs.md`
  covering when a strategy should emit `{:output, type, payload}` versus
  `{:tool_call, …}`. The distinction is the application boundary, not
  preview-vs-commit: outputs are deliverables that leave the app (delivered
  through an adapter, deduped against double-send), while tool calls are actions
  within the app's own domain — reads and in-domain writes/saves alike.

## [0.3.6] — 2026-08-12

### Fixed
- **`active_for/2` no longer raises when option keys ride in the filter list.**
  Elixir folds a trailing keyword list into a single argument, so
  `active_for(finding_key: k, limit: 1)` passes `:limit` *inside* filters — which
  0.3.5's unrecognized-filter guard turned into a runtime `ArgumentError`. The
  reserved option keys (`:limit`, `:offset`, `:order_by`, `:env`,
  `:exclude_archived`) are now routed back to opts wherever they appear, so such
  calls work and the `limit` is actually applied (in 0.3.5 and earlier it was
  silently dropped and never took effect). Genuinely unknown filter keys still
  raise.

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

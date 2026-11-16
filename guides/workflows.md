# Workflows

Workflows coordinate multiple actors in a dependency graph. Data flows between
steps via the `workflow_result/2` strategy callback and `input:` functions on
downstream steps. Workflows can be **compiled** (Elixir modules) or **dynamic**
(defined in the database and registered at runtime).

> Examples use a generic **resource** domain: a `ResourceReview` workflow that
> checks limits, then produces an advisory summary.

## Defining a compiled workflow

```elixir
defmodule MyApp.Workflows.ResourceReview do
  use Cyclium.Workflow

  workflow do
    trigger {:event, "resource.updated"}
    debounce_ms :timer.seconds(3)
    subject_key :resource_id

    step :check_limits,
      actor: :resource_monitor,
      expectation: :check_resource_limits

    step :advisory_summary,
      actor: :resource_advisor,
      expectation: :resource_advisory,
      depends_on: [:check_limits],
      input: fn _trigger, prior ->
        # prior[:check_limits] contains the map returned by
        # the limits strategy's workflow_result/2 callback
        %{resource_id: prior[:check_limits].resource_id}
      end

    on_failure :check_limits, policy: :retry, max_step_attempts: 3, backoff_ms: 5_000
    on_failure :advisory_summary, policy: :abort
  end
end
```

**Workflow debounce:** `debounce_ms` and `subject_key` coalesce rapid events
before starting the workflow. When `subject_key` is set, each unique subject
value gets its own debounce window — resource A and resource B debounce
independently. Without `subject_key`, all events for the workflow share a single
timer. Each new event resets the debounce window (trailing-edge). This is useful
for workflows that trigger on high-frequency events like `"resource.updated"`.

**One live instance per subject:** when `subject_key` is set, a subject has at
most one instance running or blocked at a time. A start for a subject that has
one (from an event, a debounce firing, or `start_workflow/4`) is refused as
`{:error, :duplicate_in_flight}`, and `[:cyclium, :workflow, :duplicate_blocked]`
fires with `reason: :live_instance`. With work claims configured, the check
runs under the subject's claim, so two nodes handling the same event yield one
instance and the other start is refused (`reason: :claim_busy` when the two
raced). A payload without the subject key is not held, and a workflow without
`subject_key` is never held.

To let a later start run beside a live instance (a debounced workflow whose
newer event must start a run of its own, say), opt out:

```elixir
workflow do
  trigger {:event, "resource.updated"}
  debounce_ms :timer.seconds(3)
  subject_key :resource_id, exclusive: false

  step :check_limits, actor: :resource_monitor, expectation: :check_resource_limits
end
```

**Episode reuse (cross-workflow dedup):** By default, workflows reuse recent
completed episodes when two workflows trigger the same actor + expectation +
input within a 5-minute window. To disable this:

```elixir
workflow do
  disable_episode_reuse

  trigger {:event, "resource.review_requested"}
  step :check_limits, actor: :resource_monitor, expectation: :check_resource_limits
end
```

**Approval gates:** a step declared with `requires_approval: true` does not
start when its dependencies are done. It waits with status
`"awaiting_approval"`, the instance becomes `:blocked`, and
`workflow.step_awaiting_approval` is broadcast (with `workflow_instance_id`
and `step_id`). `Cyclium.WorkflowEngine.approve_step/4` starts it;
`reject_step/4` fails it with `error_class` `"approval_rejected"` through the
step's failure policy (`:abort` fails the workflow, `:retry` asks again after
the backoff unless `"approval_rejected"` is in `skip_on_error_class`). Pass
`principal:` to record who decided; the decision is kept on the step's
`approval`. An approval holds for the rest of the instance, so a retry of an
approved step does not ask again.

```elixir
step :apply_change,
  actor: :change_actor,
  expectation: :apply_change,
  depends_on: [:plan_change],
  requires_approval: true

# later, from the UI or an operator:
Cyclium.WorkflowEngine.approve_step(instance_id, :apply_change,
  principal: %{"type" => "user", "id" => user_id}
)
```

**Cancellation cascade:** When a workflow fails, pending, retrying and
awaiting-approval, blocked and paused steps are automatically canceled, the
workers of running sibling steps are asked to stop at their next step
boundary, and conversations that blocked steps are waiting on are
abandoned. To also clear active findings raised by the workflow's
episodes, set `clear_findings_on_cancel` in the workflow instance metadata.

## Passing data between steps

Downstream steps receive each completed step's result via `prior`. The result
is the step episode's `classification`, `summary` and `confidence`. When the
step's strategy implements the optional `workflow_result/2` callback, the
runner calls it at converge and the map it returns is merged into that result;
its keys win on a clash. The runner keeps the map in the episode's
`metadata["workflow_result"]` (string keys), so it reaches the engine on
whichever node handles the step's completion. A callback that raises or returns
something other than a map leaves the step with the default result.

```elixir
defmodule MyApp.Strategies.ResourceLimits do
  @behaviour Cyclium.EpisodeRunner.Strategy

  # ... init, next_step, handle_result, converge as usual ...

  # Optional: extract data for downstream workflow steps
  @impl true
  def workflow_result(state, _converge_result) do
    # This map becomes prior[:check_limits] in downstream input functions
    %{resource_id: state.resource_id, classification: state.classification}
  end
end
```

## Configuration and usage

Register workflows in config:

```elixir
config :cyclium, :workflows, [MyApp.Workflows.ResourceReview]
```

The `WorkflowEngine` GenServer:

- Listens for trigger events on the Bus
- Creates a `WorkflowInstance` record to track execution
- Fires steps in dependency order (DAG validated at compile time)
- Passes data between steps via `workflow_result/2` → `input` functions
- Applies failure policies per-step: `:abort` (cancel all), `:retry` (with
  backoff), `:pause` (wait for manual intervention; see below)

### Pausing, resuming and canceling

A step paused by its `:pause` failure policy holds its instance `:blocked`
until someone acts on it:

```elixir
# Run the paused step again: a new episode, attempts + 1, instance :running
Cyclium.WorkflowEngine.resume_step(instance_id, :check_limits)

# Or give up on the instance
Cyclium.WorkflowEngine.cancel_workflow(instance_id, "operator_stop")
```

`pause_step/3` pauses a running step on request. Its episode is asked to stop
at its next step boundary (`Cyclium.Episodes.request_cancel/2`), a pending
retry is dropped, and the step is left `"paused"` with the instance
`:blocked`, the same state the `:pause` policy leaves, so `resume_step/3` runs
it again. A paused step ignores its episode's later terminal event, so a
converge that finishes after the pause cannot mark it done.

`cancel_workflow/3` ends a running or blocked instance. Running workers are
asked to stop at their next step boundary and write `:canceled` themselves;
blocked episodes are canceled directly. An episode whose worker has not
started yet (still queued, deferred to another node, or awaiting a retry)
finds the request on its row when it starts and is canceled before its first
step, so it delivers no outputs. A conversation an interactive step is waiting
on is abandoned with the reason. Unfinished steps become `"canceled"`,
retry timers are dropped, the instance becomes `:canceled`, and
`workflow.canceled` is broadcast with the `reason`, which also goes into each
canceled episode's journal. It returns `{:error, :finished}` for an instance
that is already done, failed or canceled.

`pause_step/3` returns `{:error, :not_running}` and `resume_step/3`
`{:error, :not_paused}` for a step in another state; both return
`{:error, :not_found}` for an unknown step or an instance that is not running
or blocked.

Workflows can also be started manually:

```elixir
Cyclium.WorkflowEngine.start_workflow(
  MyApp.Workflows.ResourceReview,
  %{resource_id: "123"},
  []
)
```

## Dynamic workflows

Dynamic workflows can be defined in the database and registered at runtime — no
compiled modules required. They follow the same step-dependency model as compiled
workflows but use declarative input mappings instead of Elixir functions.

### Defining a workflow in the database

Insert a row into `cyclium_workflow_definitions`:

```elixir
%Cyclium.Schemas.WorkflowDefinition{
  workflow_id: "resource_provisioning",
  trigger_type: "event",
  trigger_event: "resource.provision_requested",
  steps: Jason.encode!([
    %{
      "id" => "validate",
      "actor_id" => "validation_monitor",
      "expectation" => "validate_request",
      "depends_on" => [],
      "input_map" => %{"resource_id" => "trigger.resource_id"},
      "failure_policy" => "abort"
    },
    %{
      "id" => "provision",
      "actor_id" => "provisioning_actor",
      "expectation" => "provision_resource",
      "depends_on" => ["validate"],
      "input_map" => %{
        "resource_id" => "trigger.resource_id",
        "tier" => "prior.validate.classification.primary"
      },
      "failure_policy" => "retry",
      "max_step_attempts" => 2,
      "backoff_ms" => 30000,
      "requires_approval" => true
    }
  ]),
  enabled: true
}
```

### Input mapping syntax

Dynamic workflows use dot-notation paths instead of Elixir functions:

| Path | Resolves to |
|------|-------------|
| `"trigger.resource_id"` | `trigger_ref["resource_id"]` |
| `"prior.validate.classification.primary"` | `prior[:validate][:classification]["primary"]` |
| `"fast"` (no prefix) | Static value `"fast"` |

### Loading dynamic workflows

```elixir
# At startup — loads all enabled definitions
Cyclium.DynamicWorkflow.Loader.load_all()

# Load a single workflow
Cyclium.DynamicWorkflow.Loader.load("resource_provisioning")

# Reload after updating the definition in DB
Cyclium.DynamicWorkflow.Loader.reload("resource_provisioning")

# Unregister a workflow
Cyclium.DynamicWorkflow.Loader.unload("resource_provisioning")
```

### Starting dynamic workflows manually

```elixir
Cyclium.WorkflowEngine.start_dynamic_workflow(
  "resource_provisioning",
  %{"resource_id" => "r-123"}
)
```

A definition with `trigger_type: "event"` also starts on its `trigger_event`
(via Bus), like a compiled workflow. One with `trigger_type: "manual"` starts
only this way. The Watcher also listens for
`workflow_definition.created/updated/disabled` events for automatic refresh.

A dynamic step names its actor by id string. Its episode takes the budget,
`log_strategy` and actor `spec_rev` that actor registered for the expectation
when it booted, the same as a step of a compiled workflow; an actor id with no
registration on the node keeps the defaults.

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Dynamic Actors](dynamic_actors.md) · [Advanced](advanced.md) (workflow dry runs,
validation test kit)

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

**Cancellation cascade:** When a workflow fails, pending and retrying steps are
automatically canceled. To also clear active findings raised by the workflow's
episodes, set `clear_findings_on_cancel` in the workflow instance metadata.

## Passing data between steps

When a workflow step completes, the engine calls the strategy's optional
`workflow_result/2` callback to extract the data that downstream steps receive
via `prior`. If `workflow_result/2` is not implemented, downstream steps receive
`nil` for that step's prior.

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
  backoff), `:pause` (wait for manual intervention)

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
      "backoff_ms" => 30000
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

Dynamic workflows are event-triggered (via Bus) like compiled workflows. The
Watcher also listens for `workflow_definition.created/updated/disabled` events for
automatic refresh.

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Dynamic Actors](dynamic_actors.md) · [Advanced](advanced.md) (workflow dry runs,
validation test kit)

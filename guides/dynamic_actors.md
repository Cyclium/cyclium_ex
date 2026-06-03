# Dynamic Actors

Dynamic actors allow agent definitions to be stored in the database and hydrated
into running supervised processes at runtime — without requiring compiled Elixir
modules. This guide covers defining dynamic actors, the built-in strategy
templates, gatherers, and safe lifecycle operations.

> Examples use a generic **resource** domain.

## When to use dynamic actors

- Users create custom monitoring agents through a UI
- Agent definitions are stored per-tenant
- Agent configurations change frequently without requiring code deploys

## How it works

A single `Cyclium.DynamicActor` GenServer module serves all DB-defined actors.
Each instance is started with different config/expectations args under
`Cyclium.ActorSupervisor`. This avoids runtime module pollution — no
`Module.create/3` needed.

```
Cyclium.ActorSupervisor (DynamicSupervisor)
├── MyApp.Actors.ResourceMonitor    (compiled, use Cyclium.Actor)
├── Cyclium.DynamicActor            (from DB: "user_monitor_1")
└── Cyclium.DynamicActor            (from DB: "user_monitor_2")
```

## Defining an agent in the database

Insert a row into `cyclium_agent_definitions`:

```elixir
%Cyclium.Schemas.AgentDefinition{
  actor_id: "custom_resource_check",
  domain: "monitoring",
  strategy_template: "observe_classify_converge",   # built-in template
  config: Jason.encode!(%{max_concurrent_episodes: 3, episode_overflow: "queue"}),
  expectations: Jason.encode!([
    %{
      id: "check_target",
      trigger: %{type: "schedule", interval_ms: 300_000},
      budget: %{max_turns: 5, max_tokens: 10_000, max_wall_ms: 60_000},
      log_strategy: "timeline"
    }
  ]),
  enabled: true
}
```

## Loading dynamic actors

```elixir
# At application startup — loads all enabled definitions
Cyclium.DynamicActor.Loader.load_all()

# Load a single actor
Cyclium.DynamicActor.Loader.load("custom_resource_check")

# Reload after updating the definition in DB
Cyclium.DynamicActor.Loader.reload("custom_resource_check")

# Stop a dynamic actor
Cyclium.DynamicActor.Loader.stop("custom_resource_check")
```

## Database table

`cyclium_agent_definitions` (V7 migration):

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK |
| `actor_id` | string(255) | Unique identifier |
| `domain` | string(255) | Grouping domain |
| `config` | text (JSON) | `max_concurrent_episodes`, `episode_overflow`, etc. |
| `expectations` | text (JSON) | Array of expectation definitions |
| `strategy_ref` | string(255) | Strategy module or registry lookup key |
| `strategy_template` | string(255) | Template name (e.g. `"observe_synthesize_converge"`) |
| `strategy_config` | text (JSON) | Template parameters (gatherer, system_prompt, finding_config, etc.) |
| `enabled` | boolean | Soft toggle |
| `created_by` | string(255) | User/tenant |

## Strategy templates (data-driven strategies)

Dynamic actors use **strategy templates** — built-in parameterized strategy
modules that are configured via `strategy_config` JSON in the DB. The compiled
app defines what data sources (gatherers) and outputs are available; the DB
definition composes them.

| Template | Pattern | Use Case |
|----------|---------|----------|
| `"observe_synthesize_converge"` | Gather → LLM → Finding | Health checks, advisors, analysis |
| `"observe_classify_converge"` | Gather → Rules → Finding | Threshold/rule-based monitoring |
| `"dispatch"` | Load entities → Broadcast events | Fan-out triggers |

### Gatherers

Gatherers are compiled modules that know how to collect domain-specific data. The
compiled app implements and registers them:

```elixir
defmodule MyApp.Gatherers.ResourceData do
  @behaviour Cyclium.Gatherer

  @impl true
  def gather(trigger_payload, _opts) do
    resource_id = trigger_payload["resource_id"]
    resource = Repo.get!(Resource, resource_id)
    events = load_recent_events(resource_id)
    {:ok, %{resource: resource, events: events, event_count: length(events)}}
  end
end
```

Register in app config:

```elixir
config :cyclium, :gatherer_registry, %{
  "resource_data" => MyApp.Gatherers.ResourceData,
  "resource_metrics" => MyApp.Gatherers.ResourceMetrics
}
```

### Observe → Synthesize → Converge

The main workhorse. Gathers data, sends to LLM, maps result to findings:

```elixir
%AgentDefinition{
  actor_id: "resource_health_dynamic",
  strategy_template: "observe_synthesize_converge",
  strategy_config: Jason.encode!(%{
    "gatherer" => "resource_data",
    "system_prompt" => "You are an operations analyst. Evaluate the resource data and classify its health status.",
    "finding_config" => %{
      "actor_id_field" => "resource_health_dynamic",
      "finding_key_template" => "resource:health:${subject_id}",
      "class_field" => "class",
      "severity_field" => "severity",
      "summary_field" => "summary",
      "subject_kind" => "resource",
      "subject_id_key" => "resource_id"
    },
    "outputs" => ["email"]
  }),
  expectations: Jason.encode!([
    %{id: "evaluate", trigger: %{type: "event", event_type: "resource.check_requested"}}
  ])
}
```

### Observe → Classify → Converge

Rule-based classification without LLM. Rules are evaluated in order, first match
wins:

```elixir
%AgentDefinition{
  actor_id: "resource_risk_monitor",
  strategy_template: "observe_classify_converge",
  strategy_config: Jason.encode!(%{
    "gatherer" => "resource_metrics",
    "classify_rules" => [
      %{"field" => "percent_used", "op" => "gt", "value" => 1.0, "class" => "over_limit", "severity" => "high"},
      %{"field" => "idle_days", "op" => "gt", "value" => 30, "class" => "stale", "severity" => "medium"}
    ],
    "default_class" => "healthy",
    "default_severity" => "low",
    "finding_config" => %{
      "finding_key_template" => "resource:risk:${subject_id}",
      "subject_kind" => "resource",
      "subject_id_key" => "resource_id"
    }
  })
}
```

Rule operators: `lt`, `gt`, `eq`, `neq`, `in`, `not_in`.

### Dispatch

Fan-out pattern. Calls a gatherer that returns a list of entities, broadcasts an
event for each:

```elixir
%AgentDefinition{
  actor_id: "resource_dispatch",
  strategy_template: "dispatch",
  strategy_config: Jason.encode!(%{
    "gatherer" => "active_resources",
    "event_type" => "resource.check_requested",
    "entity_id_field" => "id",
    "entity_payload_fields" => ["id", "name"]
  })
}
```

### Strategy resolution for dynamic actors

Dynamic actors use the same `:persistent_term` registration path as compiled
actors. When a dynamic actor boots, `Loader` resolves the strategy from
`strategy_template` and injects it into each expectation —
`init_state_from_config` then registers it automatically. No strategy registry
entries needed.

If you need to override a strategy without updating the DB record, add a
`strategy_for/2` clause to your registry as usual.

Custom templates can be registered in app config:

```elixir
config :cyclium, :strategy_templates, %{
  "my_custom_template" => MyApp.Strategies.CustomTemplate
}
```

## Lifecycle and draining

Safe lifecycle operations for updating dynamic actors without losing in-flight
episodes.

### Drain and reload

```elixir
# Graceful: waits for active episodes to finish, then reloads from DB
Cyclium.DynamicActor.Lifecycle.drain_and_reload("my_monitor")

# Graceful stop (waits for episodes)
Cyclium.DynamicActor.Lifecycle.drain_and_stop("my_monitor")

# Instant stop/reload (existing behavior, may lose in-flight episodes)
Cyclium.DynamicActor.Loader.stop("my_monitor")
Cyclium.DynamicActor.Loader.reload("my_monitor")
```

### Event-driven refresh

Start the optional `Watcher` in your supervision tree for automatic refresh:

```elixir
children = [
  # ... your app ...
  Cyclium.DynamicActor.Watcher
]
```

Then broadcast events when definitions change:

```elixir
# Agent definitions:
Cyclium.Bus.broadcast("agent_definition.created", %{actor_id: "my_monitor"})
Cyclium.Bus.broadcast("agent_definition.updated", %{actor_id: "my_monitor"})
Cyclium.Bus.broadcast("agent_definition.disabled", %{actor_id: "my_monitor"})

# Workflow definitions:
Cyclium.Bus.broadcast("workflow_definition.created", %{workflow_id: "onboarding"})
Cyclium.Bus.broadcast("workflow_definition.updated", %{workflow_id: "onboarding"})
Cyclium.Bus.broadcast("workflow_definition.disabled", %{workflow_id: "onboarding"})
```

The Watcher handles each event appropriately — `created` loads, `updated`
reloads, `disabled` stops/unloads. For actors, updates use drain-and-reload to
preserve in-flight episodes.

### Deploy patterns

**Rolling deploy:**

```elixir
# In application stop callback or shutdown hook:
Cyclium.DynamicActor.Lifecycle.stop_all(drain: true, timeout: 30_000)
```

**Blue-green:** The new instance calls `Loader.load_all()` on startup. Global
name registration ensures only one instance runs per actor across the cluster.

---

**Related guides:** [Actors & Strategies](actors_and_strategies.md) ·
[Workflows](workflows.md) · [Distributed Ops](distributed_ops.md)

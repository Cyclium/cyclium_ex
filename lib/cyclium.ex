defmodule Cyclium do
  @moduledoc """
  Cyclium — an Elixir library for event-driven, expectation-based agent orchestration.

  Actors use a declarative DSL to define episodes as units of work. When
  triggers fire, episodes execute strategies that gather data, call tools,
  synthesize with LLMs, and converge into findings and outputs.

  ## Core subsystems

    * **Actor DSL** — Declarative macro-based definitions for actors, expectations,
      triggers, and budgets. Actors run as GenServers under OTP supervision.

    * **Episode Runner** — Budget-enforced execution loop with step journaling,
      checkpointing, and crash recovery. Episodes run as Tasks under a
      DynamicSupervisor — no external job queue required.

    * **Strategy Pattern** — Pluggable investigation logic with an
      `init/2 → next_step/2 → handle_result/3` lifecycle. Strategies are
      stateless modules; all state lives in the episode's strategy state map.

    * **Findings** — Persistent observations with raise/update/clear semantics,
      upsert-by-key, causality chains, TTL expiration, severity escalation,
      and post-raise enrichment hooks.

    * **Output Router** — Deduplicated, adapter-based delivery (email, Slack,
      webhooks) with approval gates and an adapter registry.

    * **Event Bus** — Phoenix.PubSub-backed event system connecting actors,
      LiveViews, and workflows without coupling.

    * **Workflow Engine** — Multi-actor coordination with dependency graphs,
      failure policies, retry with backoff, and cancellation cascade.

    * **Work Claims** — Opt-in lease-based distributed coordination for
      at-most-once episode execution across clustered nodes. Also coordinates
      trigger request dispatch and finding sweeps.

    * **Trigger-Only Mode** — Decouples event processing from episode execution.
      Trigger-only nodes write deferred requests to the DB; full-mode nodes
      pick them up via a poller backed by work claims.

  ## Configuration

  At minimum, Cyclium requires a repo:

      config :cyclium, :repo, MyApp.Repo

  See the README for the full configuration reference including work claims,
  node identity, mode switching, and telemetry.
  """

  def repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

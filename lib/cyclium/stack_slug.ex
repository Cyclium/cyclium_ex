defmodule Cyclium.StackSlug do
  @moduledoc """
  Reads the current stack slug from application config.

  A "stack" is one logical cyclium cluster sharing a database with other
  clusters. The slug identifies which cluster owns a given episode, trigger
  request, or workflow instance and is used by Recovery and the
  trigger-request poller to avoid stealing work across clusters.

  ## Stacks and supervised actors

  `Cyclium` itself exposes no per-actor DSL option for stacks — the slug
  is read once per cluster and stamped onto every row that cluster's
  actors produce. Which actors actually start on a given cluster is the
  consumer's decision, implemented in their own supervisor.

  The simplest pattern is to keep a stack-specific actor list per
  deployment:

      # On the stack_a cluster's host app:
      config :cyclium, :stack_slug, "stack_a"
      config :my_app, :cyclium_actors, [StackAOnlyActor, SharedActor]

      # On the stack_b cluster's host app:
      config :cyclium, :stack_slug, "stack_b"
      config :my_app, :cyclium_actors, [StackBOnlyActor, SharedActor]

  A richer pattern declares the allowed stacks on each actor's child-spec
  and has the supervisor filter the list at init time:

      config :my_app, :cyclium_actors, [
        {SharedActor, []},
        {StackAOnlyActor, stacks: [:stack_a]},
        {CrossStackActor, stacks: [:stack_a, :stack_b]}
      ]

      # In the supervisor's init/1:
      stack = Application.get_env(:cyclium, :stack_slug)
      actors = Enum.filter(children, &actor_matches_stack?(&1, stack))

  Either way, every actor that does end up starting inherits that
  cluster's `:stack_slug`. Any episode, workflow instance, or deferred
  trigger request those actors create is stamped with the slug at
  insertion time, so Recovery on that cluster only sees its own work and
  does not reschedule episodes whose in-memory state lives on another
  cluster's nodes.

  ## Configuration

  Set the slug statically:

      config :cyclium, :stack_slug, "stack_a"

  or from an env var so the same release can be deployed into multiple
  stacks:

      config :cyclium, :stack_slug, System.get_env("CYCLIUM_STACK_SLUG")

  A `nil` / unset slug means "single-stack deploy" — rows are stamped
  `NULL` and Recovery is unscoped (current behavior for consumers that
  have not adopted multi-stack).
  """

  @doc """
  Returns the configured stack slug as a string, or `nil` if unset.

  Used when stamping rows at creation time and when filtering recovery
  scans. A `nil` result means "single-stack deploy" — stamp nothing and
  skip scoping.
  """
  @spec current() :: String.t() | nil
  def current do
    case Application.get_env(:cyclium, :stack_slug) do
      nil -> nil
      "" -> nil
      slug -> to_string(slug)
    end
  end

  @doc """
  Returns the configured stack slug as a string, falling back to `default`
  when unset. Call sites that need a non-nil value (e.g. stamping the
  `source_stack` column on a deferred trigger request) should prefer this.
  """
  @spec current(String.t() | atom()) :: String.t()
  def current(default) when is_binary(default) or is_atom(default) do
    current() || to_string(default)
  end
end

defmodule Cyclium.StackSlug do
  @moduledoc """
  Reads the current stack slug from application config.

  A "stack" is one logical cyclium cluster sharing a database with other
  clusters. The slug identifies which cluster owns a given episode, trigger
  request, or workflow instance and is used by Recovery and the
  trigger-request poller to avoid stealing work across clusters.

  ## Stacks and supervised actors

  Stacks are **cluster-level**, not per-actor. There is no `stack:` option
  on an actor's DSL block. Instead, the cluster's host app partitions work
  by choosing which actors to supervise on which node:

      # On the stack_a cluster's host app:
      config :cyclium, :stack_slug, "stack_a"
      config :my_app, :cyclium_actors, [StackAOnlyActor, SharedActor]

      # On the stack_b cluster's host app:
      config :cyclium, :stack_slug, "stack_b"
      config :my_app, :cyclium_actors, [StackBOnlyActor, SharedActor]

  Every actor the supervisor starts on a node inherits that node's
  `:stack_slug`. Any episode, workflow instance, or deferred trigger
  request those actors create is stamped with the slug at insertion time,
  so Recovery on that cluster only sees its own work and does not
  reschedule episodes whose in-memory state lives on another cluster's
  nodes.

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

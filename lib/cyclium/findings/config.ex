defmodule Cyclium.Findings.Config do
  @moduledoc """
  ETS-backed registry for per-expectation finding configuration.

  Stores enrichment callbacks, escalation rules, and default TTL so that
  the findings write path and escalation sweep can look up config without
  requiring application env.

  ## Registration

  Called automatically during actor init for expectations that declare
  `finding_enrichment`, `escalation_rules`, or `finding_ttl_seconds`.

  ## Fallback

  When no per-expectation config is registered, `Cyclium.Findings` and
  `Cyclium.Findings.Escalation` fall back to application env for
  backwards compatibility.
  """

  @table :cyclium_findings_config

  @doc "Idempotent ETS table creation."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ref ->
        @table
    end
  end

  @doc """
  Register finding config for an actor + expectation.

  Config map may contain:
    - `:enrichment` — callback fun/2 or {mod, fun}
    - `:escalation_rules` — %{"class" => [%{after_minutes: n, escalate_to: severity}]}
    - `:default_ttl_seconds` — default TTL for findings without explicit ttl_seconds
  """
  def register(actor_id, expectation_id, config) when is_map(config) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}
    :ets.insert(@table, {key, config})
    :ok
  end

  @doc "Get finding config for an actor + expectation. Returns nil if not registered."
  def get(actor_id, expectation_id) do
    ensure_table()
    key = {to_string(actor_id), to_string(expectation_id)}

    case :ets.lookup(@table, key) do
      [{^key, config}] -> config
      [] -> nil
    end
  end

  @doc """
  Get the enrichment callback for an actor + expectation.

  Falls back to `Application.get_env(:cyclium, :finding_enrichment)`.
  """
  def enrichment_for(actor_id, expectation_id) do
    case get(actor_id, expectation_id) do
      %{enrichment: callback} when not is_nil(callback) -> callback
      _ -> Application.get_env(:cyclium, :finding_enrichment)
    end
  end

  @doc """
  Get the default TTL seconds for an actor + expectation.

  Returns nil if not configured.
  """
  def default_ttl_for(actor_id, expectation_id) do
    case get(actor_id, expectation_id) do
      %{default_ttl_seconds: ttl} when is_integer(ttl) and ttl > 0 -> ttl
      _ -> nil
    end
  end

  @doc """
  Collect all registered escalation rules across all expectations.

  Returns a merged map of `%{class => rules}`. When multiple expectations
  register rules for the same class, rules are merged (later registrations
  override earlier ones for the same class).

  Falls back to `Application.get_env(:cyclium, :escalation_rules, %{})` when
  no per-expectation rules are registered.
  """
  def all_escalation_rules do
    ensure_table()

    per_expectation =
      :ets.foldl(
        fn {_key, config}, acc ->
          case Map.get(config, :escalation_rules) do
            rules when is_map(rules) and map_size(rules) > 0 ->
              Map.merge(acc, rules)

            _ ->
              acc
          end
        end,
        %{},
        @table
      )

    if map_size(per_expectation) > 0 do
      per_expectation
    else
      Application.get_env(:cyclium, :escalation_rules, %{})
    end
  end
end

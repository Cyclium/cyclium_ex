defmodule Cyclium.Findings do
  @moduledoc """
  Context for finding queries and lifecycle operations.

  Read-path: strategies query active findings during `init/2`.
  Write-path: post-converge persists raise/update/clear actions.

  Subject queries use denormalized `subject_kind` and `subject_id` columns
  instead of JSON operators for SQL Server 2017 compatibility.
  Upserts use transactions (read-then-write) instead of `ON CONFLICT`
  for SQL Server compatibility.
  """

  import Ecto.Query
  alias Cyclium.Schemas.Finding

  defp repo, do: Cyclium.repo()

  def get(id), do: repo().get(Finding, id)

  def get!(id), do: repo().get!(Finding, id)

  @doc """
  Query active findings with flexible filters.

  ## Examples

      Cyclium.Findings.active_for(actor: :po_status, class: "po_stalled")
      Cyclium.Findings.active_for(subject: %{kind: "po", id: "PO-1955"})
      Cyclium.Findings.active_for(subject: %{kind: "resource"})
      Cyclium.Findings.active_for(finding_key: "po_stalled:PO-1955")
      Cyclium.Findings.active_for(class: "non_responsive")

  An unrecognized filter key raises `ArgumentError` rather than being silently
  dropped — a dropped filter returns a superset of what was asked for. Reserved
  option keys (`:limit`, `:offset`, `:order_by`, `:env`, `:exclude_archived`) are
  the exception: they are accepted in the filter list too, so
  `active_for(finding_key: k, limit: 1)` works despite Elixir folding the
  trailing keywords into one argument.

  ## Options

    * `:limit` — max rows to return
    * `:offset` — rows to skip (default: 0)
    * `:order_by` — override the default `[desc: :updated_at]` ordering. Accepts
      an allow-listed column (`:updated_at`, `:raised_at`, `:inserted_at`),
      optionally as `{dir, column}` (e.g. `{:desc, :raised_at}`). `raised_at` is
      the better signal for context: an in-place update bumps `updated_at`
      without a new run, so "most recently touched" and "most recently found"
      diverge.
    * `:exclude_archived` — when `true`, excludes findings with a non-nil `archived_at` (default: `false`)
    * `:env` — override the env scope (defaults to `Cyclium.Env.current()`). Pass
      a string to read another env's findings (demo/staging inspection or
      backfill), or `nil` to target the unset/default env explicitly.
  """
  def active_for(filters, opts \\ []) when is_list(filters) do
    {filters, opts} = split_reserved_opts(filters, opts)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)
    {dir, column} = order_by(opts)

    query =
      from(f in Finding, where: f.status == :active, order_by: [{^dir, field(f, ^column)}])
      |> apply_filters(filters)
      |> maybe_exclude_archived(opts)
      |> scope_env(read_env(opts))

    query = if limit, do: query |> limit(^limit) |> offset(^offset), else: query

    repo().all(query)
  end

  @order_columns [:updated_at, :raised_at, :inserted_at]

  # Allow-listed ordering — never interpolate a caller-supplied column into an
  # order_by unchecked. Default preserves the historical [desc: :updated_at].
  defp order_by(opts) do
    case Keyword.get(opts, :order_by) do
      nil -> {:desc, :updated_at}
      {dir, col} when dir in [:asc, :desc] and col in @order_columns -> {dir, col}
      col when col in @order_columns -> {:desc, col}
      other -> raise ArgumentError, "Cyclium.Findings: invalid :order_by #{inspect(other)}"
    end
  end

  @doc "Count active findings matching the given filters. Accepts same opts as `active_for/2`."
  def count_active(filters \\ [], opts \\ []) when is_list(filters) do
    {filters, opts} = split_reserved_opts(filters, opts)

    from(f in Finding, where: f.status == :active, select: count(f.id))
    |> apply_filters(filters)
    |> maybe_exclude_archived(opts)
    |> scope_env(read_env(opts))
    |> repo().one()
  end

  # Option keys are reserved and never treated as filters. Because Elixir folds a
  # trailing keyword list into one argument, `active_for(finding_key: k, limit: 1)`
  # passes limit *inside* filters — so route reserved keys back to opts rather
  # than letting apply_filters raise on them. An explicit opts arg still wins.
  @reserved_opts [:limit, :offset, :order_by, :env, :exclude_archived]

  defp split_reserved_opts(filters, opts) when is_list(filters) do
    if Keyword.keyword?(filters) do
      {reserved, real_filters} = Keyword.split(filters, @reserved_opts)
      {real_filters, Keyword.merge(reserved, opts)}
    else
      {filters, opts}
    end
  end

  # Cordon reads/writes to an env (see Cyclium.Env). Strict equality: a NULL env
  # row belongs to the unset/default env, so an env-tagged node sees only its own
  # findings and never the default node's, and vice-versa. In a single-env
  # deployment every row is NULL and the node's env is nil, so this matches
  # everything — byte-identical to pre-env behavior.
  defp scope_env(query, nil), do: from(f in query, where: is_nil(f.env))
  defp scope_env(query, env), do: from(f in query, where: f.env == ^env)

  # Reads default to the node's env, but accept an explicit `:env` override so a
  # dev/Mix task can inspect or backfill another env's findings (e.g. demo,
  # staging). Pass `env: nil` to target the default env explicitly.
  defp read_env(opts), do: Keyword.get(opts, :env, Cyclium.Env.current())

  # Writes derive their env from the *episode* that raised them, so backfilling
  # is as simple as creating an episode in the target env (`source_env: "demo"`)
  # and persisting findings against it — the finding follows the episode. An
  # explicit `:env` in the raise params still wins for the rare direct case.
  defp write_env(episode), do: Map.get(episode, :source_env)

  # The changes an update to an existing finding may apply: whitelisted to
  # the mutable fields, nils rejected — an omitted field on a re-raise must
  # not clear the stored value (and some adapters can't take a nil param
  # over a stored value anyway).
  defp safe_changes(changes, now, allowed) when is_map(changes) and is_list(allowed) do
    changes
    |> Map.take(allowed)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:updated_at, now)
  end

  defp get_active_by_key(repo, finding_key, env) do
    from(f in Finding, where: f.finding_key == ^finding_key and f.status == :active)
    |> scope_env(env)
    |> repo.one()
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:actor, actor_id} | rest]) do
    actor_str = to_string(actor_id)
    query |> where([f], f.actor_id == ^actor_str) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:class, class} | rest]) do
    query |> where([f], f.class == ^class) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:finding_key, key} | rest]) do
    query |> where([f], f.finding_key == ^key) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:subject, %{kind: kind, id: id}} | rest]) do
    kind_str = to_string(kind)
    id_str = to_string(id)

    query
    |> where([f], f.subject_kind == ^kind_str and f.subject_id == ^id_str)
    |> apply_filters(rest)
  end

  # Kind-only subject filter, e.g. all findings about resources regardless of id.
  defp apply_filters(query, [{:subject, %{kind: kind}} | rest]) do
    kind_str = to_string(kind)
    query |> where([f], f.subject_kind == ^kind_str) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:caused_by, key} | rest]) do
    query |> where([f], f.caused_by_key == ^key) |> apply_filters(rest)
  end

  # Raise on unrecognized filters — dropping one returns a superset of what was
  # asked for, a wrong result that looks like real data.
  defp apply_filters(_query, [{key, _value} | _rest]) do
    raise ArgumentError,
          "Cyclium.Findings: unrecognized filter #{inspect(key)}. " <>
            "Supported filters: :actor, :class, :finding_key, :subject, :caused_by."
  end

  defp apply_filters(_query, [other | _rest]) do
    raise ArgumentError,
          "Cyclium.Findings: malformed filter #{inspect(other)}. " <>
            "Filters must be a keyword list of {key, value} tuples."
  end

  defp maybe_exclude_archived(query, opts) do
    if Keyword.get(opts, :exclude_archived, false) do
      where(query, [f], is_nil(f.archived_at))
    else
      query
    end
  end

  @doc """
  Returns true if an active finding with the given key was updated within `window_ms` milliseconds.

  Useful for per-subject dedup in strategies — skip re-runs when a recent finding already exists.

  ## Examples

      Cyclium.Findings.recent?("client:advisor:123", :timer.minutes(5))
  """
  def recent?(finding_key, window_ms) when is_binary(finding_key) and is_integer(window_ms) do
    case active_for(finding_key: finding_key) do
      [%{updated_at: updated_at} | _] ->
        DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) < window_ms

      _ ->
        false
    end
  end

  @doc """
  Mode-aware query: automatically prefixes `:actor` and `:finding_key` filters
  when the episode is a dry run with `persist_findings` enabled.

  In live mode (or dry runs without persist_findings), behaves identically to `active_for/2`.
  In dry run mode with a persist prefix, rewrites filter keys so strategies can
  transparently read their own dry run findings.

  ## Examples

      # In a strategy's init/2, pass the episode to get mode-aware results:
      Cyclium.Findings.active_for_mode([actor: "po_monitor"], episode)

      # Dry run with persist_findings: true → queries actor: "dry_run:po_monitor"
      # Live mode → queries actor: "po_monitor" (unchanged)
  """
  def active_for_mode(filters, episode, opts \\ []) when is_list(filters) do
    alias Cyclium.DryRun.FindingPrefixer

    case FindingPrefixer.persist_prefix(episode) do
      nil ->
        active_for(filters, opts)

      prefix ->
        # Only :actor and :finding_key are prefixed. Subject identity is not
        # prefixed in a dry run, so :subject (and any other filter) passes
        # through unchanged by design — this is NOT the silent-drop pattern that
        # active_for/2's catch-all guards against.
        prefixed_filters =
          Enum.map(filters, fn
            {:actor, actor_id} -> {:actor, "#{prefix}:#{actor_id}"}
            {:finding_key, key} -> {:finding_key, "#{prefix}:#{key}"}
            other -> other
          end)

        active_for(prefixed_filters, opts)
    end
  end

  @doc """
  Project findings into compact, JSON-safe maps for strategy context assembly.

  Strategies read active findings during context assembly, and that payload is
  journaled by the episode runner (JSON-encoded for SQL Server via the Tds
  adapter). Raw `%Finding{}` Ecto structs are **not** `Jason.Encoder`-able —
  they carry `__meta__` and association fields — so handing them to a strategy
  crashes the episode at its first journal write the moment the actor has any
  active finding. Always project findings through this before putting them in a
  strategy's context.

  The projection is also better prompt context: one summary-shaped line per
  finding instead of every finding's full `evidence_refs` narrative (which can
  run to multiple KB and would otherwise ride into every episode's first prompt
  and journal row).

  Accepts the same `opts` as `project_finding/2` (e.g. `:summary_limit`).
  """
  def project_for_context(findings, opts \\ []) when is_list(findings) do
    Enum.map(findings, &project_finding(&1, opts))
  end

  # Findings-context grows with every subject appraised; an unbounded summary
  # rides into every episode's first prompt and journal row. Bound it by
  # default; callers that need more can raise `:summary_limit`.
  @default_summary_limit 500

  @doc """
  Project a single `%Finding{}` into a compact, JSON-safe summary map.

  ## Options

    * `:summary_limit` — max `summary` length in graphemes (default
      `#{@default_summary_limit}`); longer summaries are truncated with an `…`
      suffix. Pass `nil` to disable truncation.
  """
  def project_finding(%Finding{} = f, opts \\ []) do
    limit = Keyword.get(opts, :summary_limit, @default_summary_limit)

    %{
      "finding_key" => f.finding_key,
      "class" => f.class,
      "status" => f.status && to_string(f.status),
      "severity" => f.severity && to_string(f.severity),
      "confidence" => f.confidence,
      "summary" => truncate_summary(f.summary, limit),
      "subject_kind" => f.subject_kind,
      "subject_id" => f.subject_id
    }
  end

  defp truncate_summary(summary, nil), do: summary
  defp truncate_summary(summary, _limit) when not is_binary(summary), do: summary

  defp truncate_summary(summary, limit) when is_integer(limit) and limit > 0 do
    if String.length(summary) > limit do
      String.slice(summary, 0, limit) <> "…"
    else
      summary
    end
  end

  # --- Causality queries ---

  @doc """
  Returns active child findings caused by the given finding key.
  """
  def caused_by(finding_key) when is_binary(finding_key) do
    active_for(caused_by: finding_key)
  end

  @doc """
  Walks the causal chain upward from a finding, returning ancestors.

  Starting from the given finding, follows `caused_by_key` links up
  to `max_depth` levels. Returns a list of findings from immediate parent
  to root (oldest ancestor).

  ## Options

    * `:max_depth` — maximum chain depth (default: 10)
  """
  def causal_chain(finding_key, opts \\ []) when is_binary(finding_key) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    do_causal_chain(finding_key, max_depth, [])
  end

  defp do_causal_chain(_key, 0, acc), do: Enum.reverse(acc)

  defp do_causal_chain(finding_key, depth, acc) do
    chain_query =
      from(f in Finding, where: f.finding_key == ^finding_key, limit: 1)
      |> scope_env(Cyclium.Env.current())

    case repo().one(chain_query) do
      nil ->
        Enum.reverse(acc)

      %{caused_by_key: nil} = finding ->
        Enum.reverse([finding | acc])

      %{caused_by_key: parent_key} = finding ->
        do_causal_chain(parent_key, depth - 1, [finding | acc])
    end
  end

  @doc """
  Returns the root cause finding for the given finding key.

  Walks up the causal chain and returns the first finding with no `caused_by_key`.
  Returns `nil` if the finding itself is not found.
  """
  def root_cause(finding_key, opts \\ []) when is_binary(finding_key) do
    case causal_chain(finding_key, opts) do
      [] -> nil
      chain -> List.last(chain)
    end
  end

  # --- Write path (Phase 3) ---

  @doc """
  Persist a finding action from a ConvergeResult.

  ## Actions

    - `{:raise, params}` — upsert active finding (last writer wins on mutable fields)
    - `{:update, key, changes}` — update mutable fields on an active finding
    - `{:clear, key}` — idempotent clear (set status to `:cleared`)
    - `{:clear, key, reason}` — clear with reason stored in evidence_refs
  """
  def persist_finding({:raise, params}, episode) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    finding_key = Map.fetch!(params, :finding_key)

    # Apply default TTL from expectation config if no explicit ttl_seconds
    params = maybe_apply_default_ttl(params, episode)

    # Compute expires_at from ttl_seconds if provided
    params = maybe_apply_ttl(params, now)

    # Transaction-based upsert for SQL Server 2017 compatibility
    env = Map.get(params, :env, write_env(episode))

    result =
      repo().transaction(fn repo ->
        case get_active_by_key(repo, finding_key, env) do
          nil ->
            attrs =
              params
              |> Map.put(:raised_by_episode_id, episode.id)
              |> Map.put(:expectation_id, episode.expectation_id)
              |> Map.put_new(:raised_at, now)
              |> Map.put_new(:status, :active)
              |> Map.put(:updated_at, now)
              |> Map.put_new(:env, env)

            repo.insert!(Finding.changeset(%Finding{}, attrs))

          existing ->
            changes =
              safe_changes(params, now, [
                :class,
                :confidence,
                :severity,
                :evidence_refs,
                :summary,
                :subject,
                :subject_kind,
                :subject_id,
                :caused_by_key
              ])

            repo.update!(Finding.changeset(existing, changes))
        end
      end)

    case result do
      {:ok, finding} ->
        finding = maybe_enrich(finding, episode)
        emit_finding_telemetry(:raised, finding)
        {:ok, finding}

      {:error, _} = err ->
        err
    end
  end

  def persist_finding({:update, finding_key, changes}, episode) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_active_by_key(repo(), finding_key, write_env(episode)) do
      nil ->
        {:error, :not_found}

      existing ->
        safe_changes =
          safe_changes(changes, now, [:confidence, :severity, :evidence_refs, :summary])

        case existing |> Finding.changeset(safe_changes) |> repo().update() do
          {:ok, updated} ->
            emit_finding_telemetry(:raised, updated)
            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  def persist_finding({:clear, finding_key}, episode) do
    persist_finding({:clear, finding_key, nil}, episode)
  end

  def persist_finding({:clear, finding_key, reason}, episode) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_active_by_key(repo(), finding_key, write_env(episode)) do
      nil ->
        # Idempotent — already cleared or never existed
        :ok

      existing ->
        attrs = %{
          status: :cleared,
          cleared_by_episode_id: episode.id,
          cleared_at: now,
          updated_at: now
        }

        attrs =
          if reason do
            evidence = Map.put(existing.evidence_refs || %{}, "cleared_reason", reason)
            Map.put(attrs, :evidence_refs, evidence)
          else
            attrs
          end

        case existing |> Finding.changeset(attrs) |> repo().update() do
          {:ok, cleared} ->
            emit_finding_telemetry(:cleared, cleared)
            {:ok, cleared}

          {:error, _} = err ->
            err
        end
    end
  end

  defp maybe_enrich(finding, episode) do
    callback = Cyclium.Findings.Config.enrichment_for(episode.actor_id, episode.expectation_id)

    case callback do
      nil ->
        finding

      callback ->
        try do
          result =
            case callback do
              fun when is_function(fun, 2) -> fun.(finding, episode)
              {mod, fun} -> apply(mod, fun, [finding, episode])
            end

          case result do
            {:ok, enrichments} when is_map(enrichments) ->
              allowed = Map.take(enrichments, [:evidence_refs, :summary, :confidence])

              if map_size(allowed) > 0 do
                now = DateTime.utc_now() |> DateTime.truncate(:second)
                changes = Map.put(allowed, :updated_at, now)

                case finding |> Finding.changeset(changes) |> repo().update() do
                  {:ok, updated} -> updated
                  {:error, _} -> finding
                end
              else
                finding
              end

            :skip ->
              finding

            _ ->
              finding
          end
        rescue
          error ->
            require Logger

            Logger.warning("Finding enrichment callback failed: #{inspect(error)}",
              cyclium_finding_key: finding.finding_key
            )

            finding
        end
    end
  end

  defp maybe_apply_default_ttl(%{ttl_seconds: _} = params, _episode), do: params
  defp maybe_apply_default_ttl(%{expires_at: _} = params, _episode), do: params

  defp maybe_apply_default_ttl(params, episode) do
    case Cyclium.Findings.Config.default_ttl_for(episode.actor_id, episode.expectation_id) do
      nil -> params
      ttl -> Map.put(params, :ttl_seconds, ttl)
    end
  end

  defp maybe_apply_ttl(%{ttl_seconds: ttl} = params, now) when is_integer(ttl) and ttl > 0 do
    expires_at = DateTime.add(now, ttl, :second)

    params
    |> Map.delete(:ttl_seconds)
    |> Map.put_new(:expires_at, expires_at)
  end

  defp maybe_apply_ttl(params, _now), do: Map.delete(params, :ttl_seconds)

  defp emit_finding_telemetry(event, finding) do
    :telemetry.execute(
      [:cyclium, :finding, event],
      %{count: 1},
      %{finding_key: finding.finding_key, actor_id: finding.actor_id, class: finding.class}
    )
  end
end

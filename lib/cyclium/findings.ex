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
      Cyclium.Findings.active_for(finding_key: "po_stalled:PO-1955")
      Cyclium.Findings.active_for(class: "non_responsive")

  ## Options

    * `:limit` — max rows to return
    * `:offset` — rows to skip (default: 0)
    * `:exclude_archived` — when `true`, excludes findings with a non-nil `archived_at` (default: `false`)
  """
  def active_for(filters, opts \\ []) when is_list(filters) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(f in Finding, where: f.status == :active, order_by: [desc: f.updated_at])
      |> apply_filters(filters)
      |> maybe_exclude_archived(opts)

    query = if limit, do: query |> limit(^limit) |> offset(^offset), else: query

    repo().all(query)
  end

  @doc "Count active findings matching the given filters. Accepts same opts as `active_for/2`."
  def count_active(filters \\ [], opts \\ []) when is_list(filters) do
    from(f in Finding, where: f.status == :active, select: count(f.id))
    |> apply_filters(filters)
    |> maybe_exclude_archived(opts)
    |> repo().one()
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

  defp apply_filters(query, [{:caused_by, key} | rest]) do
    query |> where([f], f.caused_by_key == ^key) |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

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
        prefixed_filters =
          Enum.map(filters, fn
            {:actor, actor_id} -> {:actor, "#{prefix}:#{actor_id}"}
            {:finding_key, key} -> {:finding_key, "#{prefix}:#{key}"}
            other -> other
          end)

        active_for(prefixed_filters, opts)
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
    case repo().one(from(f in Finding, where: f.finding_key == ^finding_key, limit: 1)) do
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
    result =
      repo().transaction(fn repo ->
        case repo.get_by(Finding, finding_key: finding_key, status: :active) do
          nil ->
            attrs =
              params
              |> Map.put(:raised_by_episode_id, episode.id)
              |> Map.put(:expectation_id, episode.expectation_id)
              |> Map.put_new(:raised_at, now)
              |> Map.put_new(:status, :active)
              |> Map.put(:updated_at, now)

            repo.insert!(Finding.changeset(%Finding{}, attrs))

          existing ->
            mutable =
              Map.take(params, [
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

            changes = Map.put(mutable, :updated_at, now)

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

  def persist_finding({:update, finding_key, changes}, _episode) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case repo().get_by(Finding, finding_key: finding_key, status: :active) do
      nil ->
        {:error, :not_found}

      existing ->
        allowed = [:confidence, :severity, :evidence_refs, :summary]
        safe_changes = changes |> Map.take(allowed) |> Map.put(:updated_at, now)

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

    case repo().get_by(Finding, finding_key: finding_key, status: :active) do
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

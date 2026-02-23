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

  @doc """
  Query active findings with flexible filters.

  ## Examples

      Cyclium.Findings.active_for(actor: :po_status, class: "po_stalled")
      Cyclium.Findings.active_for(subject: %{kind: "po", id: "PO-1955"})
      Cyclium.Findings.active_for(finding_key: "po_stalled:PO-1955")
      Cyclium.Findings.active_for(class: "non_responsive")
  """
  def active_for(filters) when is_list(filters) do
    from(f in Finding, where: f.status == :active)
    |> apply_filters(filters)
    |> repo().all()
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

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

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

    # Transaction-based upsert for SQL Server 2017 compatibility
    result = repo().transaction(fn repo ->
      case repo.get_by(Finding, finding_key: finding_key, status: :active) do
        nil ->
          attrs =
            params
            |> Map.put(:raised_by_episode_id, episode.id)
            |> Map.put_new(:raised_at, now)
            |> Map.put_new(:status, :active)
            |> Map.put(:updated_at, now)

          repo.insert!(Finding.changeset(%Finding{}, attrs))

        existing ->
          mutable = Map.take(params, [:confidence, :severity, :evidence_refs, :summary,
                                       :subject, :subject_kind, :subject_id])
          changes = Map.put(mutable, :updated_at, now)

          repo.update!(Finding.changeset(existing, changes))
      end
    end)

    case result do
      {:ok, finding} ->
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

  defp emit_finding_telemetry(event, finding) do
    :telemetry.execute(
      [:cyclium, :finding, event],
      %{count: 1},
      %{finding_key: finding.finding_key, actor_id: finding.actor_id, class: finding.class}
    )
  end
end

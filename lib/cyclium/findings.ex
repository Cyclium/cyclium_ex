defmodule Cyclium.Findings do
  @moduledoc """
  Context for finding queries. Phase 1 is read-path only —
  strategies query active findings during `init/2`.

  Subject queries use denormalized `subject_kind` and `subject_id` columns
  instead of JSON operators for SQL Server 2017 compatibility.
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
end

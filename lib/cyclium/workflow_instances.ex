defmodule Cyclium.WorkflowInstances do
  @moduledoc """
  Context for workflow instance CRUD operations.
  """

  alias Cyclium.Schemas.WorkflowInstance

  defp repo, do: Cyclium.repo()

  def create(attrs) do
    %WorkflowInstance{}
    |> WorkflowInstance.changeset(attrs)
    |> repo().insert()
  end

  def get!(id) do
    repo().get!(WorkflowInstance, id)
  end

  def get(id) do
    repo().get(WorkflowInstance, id)
  end

  def update_status(id, status) do
    instance = get!(id)

    attrs =
      %{status: status}
      |> maybe_set_finished_at(status)

    instance
    |> WorkflowInstance.changeset(attrs)
    |> repo().update()
  end

  def update_step_states(id, step_states) do
    instance = get!(id)

    instance
    |> WorkflowInstance.changeset(%{step_states: step_states, updated_at: now()})
    |> repo().update()
  end

  defp maybe_set_finished_at(attrs, status) when status in [:done, :failed, :canceled] do
    Map.put_new(attrs, :finished_at, now())
  end

  defp maybe_set_finished_at(attrs, _status), do: attrs

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

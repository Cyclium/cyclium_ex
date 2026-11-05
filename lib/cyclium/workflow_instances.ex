defmodule Cyclium.WorkflowInstances do
  @moduledoc """
  Context for workflow instance CRUD operations.
  """

  import Ecto.Query, only: [from: 2]

  alias Cyclium.Schemas.WorkflowInstance

  @live_statuses [:running, :blocked]

  defp repo, do: Cyclium.repo()

  def create(attrs) do
    %WorkflowInstance{}
    |> WorkflowInstance.changeset(attrs |> put_stack_slug() |> put_source_env())
    |> repo().insert()
  end

  defp put_stack_slug(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :source_stack) or Map.has_key?(attrs, "source_stack") do
      attrs
    else
      case Cyclium.StackSlug.current() do
        nil -> attrs
        slug -> Map.put(attrs, :source_stack, slug)
      end
    end
  end

  defp put_source_env(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :source_env) or Map.has_key?(attrs, "source_env") do
      attrs
    else
      case Cyclium.Env.current() do
        nil -> attrs
        env -> Map.put(attrs, :source_env, env)
      end
    end
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

  @doc """
  Whether `workflow_id` has an instance still running or blocked for
  `subject_value` on `source_stack` (nil when the node has no stack slug).
  """
  @spec live_for_subject?(binary(), binary(), binary() | nil) :: boolean()
  def live_for_subject?(workflow_id, subject_value, source_stack)
      when is_binary(workflow_id) and is_binary(subject_value) do
    from(i in WorkflowInstance,
      where:
        i.workflow_id == ^workflow_id and i.subject_value == ^subject_value and
          i.status in ^@live_statuses
    )
    |> where_stack(source_stack)
    |> repo().exists?()
  end

  defp where_stack(query, nil), do: from(i in query, where: is_nil(i.source_stack))
  defp where_stack(query, stack), do: from(i in query, where: i.source_stack == ^stack)

  defp maybe_set_finished_at(attrs, status) when status in [:done, :failed, :canceled] do
    Map.put_new(attrs, :finished_at, now())
  end

  defp maybe_set_finished_at(attrs, _status), do: attrs

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

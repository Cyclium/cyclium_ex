defmodule Cyclium.WorkflowInstances do
  @moduledoc """
  Context for workflow instance CRUD operations.
  """

  alias Cyclium.Schemas.WorkflowInstance

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

  defp maybe_set_finished_at(attrs, status) when status in [:done, :failed, :canceled] do
    Map.put_new(attrs, :finished_at, now())
  end

  defp maybe_set_finished_at(attrs, _status), do: attrs

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

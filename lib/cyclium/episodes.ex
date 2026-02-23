defmodule Cyclium.Episodes do
  @moduledoc """
  Context for episode CRUD operations.
  """

  import Ecto.Query
  alias Cyclium.Schemas.Episode

  defp repo, do: Cyclium.repo()

  def create(attrs) do
    %Episode{}
    |> Episode.changeset(attrs)
    |> repo().insert()
  end

  def get!(id) do
    repo().get!(Episode, id)
  end

  def get(id) do
    repo().get(Episode, id)
  end

  def list_by_status(statuses) when is_list(statuses) do
    from(e in Episode, where: e.status in ^statuses, order_by: [asc: e.started_at])
    |> repo().all()
  end

  def update_status(episode_id, status) do
    update_status(episode_id, status, [])
  end

  def update_status(episode_id, status, extra_fields) do
    episode = get!(episode_id)

    attrs =
      extra_fields
      |> Enum.into(%{})
      |> Map.put(:status, status)
      |> maybe_set_finished_at(status)

    episode
    |> Episode.changeset(attrs)
    |> repo().update()
  end

  defp maybe_set_finished_at(attrs, status) when status in [:done, :failed, :partially_failed, :canceled] do
    Map.put_new(attrs, :finished_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp maybe_set_finished_at(attrs, _status), do: attrs
end

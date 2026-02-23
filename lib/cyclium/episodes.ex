defmodule Cyclium.Episodes do
  @moduledoc """
  Context for episode CRUD operations and lifecycle management.
  """

  import Ecto.Query
  alias Cyclium.Schemas.{Episode, EpisodeStep, Output}

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

  @doc """
  Execute the cancellation sequence for an episode (spec §4.9).

  1. Journal :episode_failed step with error_class "canceled"
  2. Set status to :canceled
  3. Cancel pending outputs (:proposed → :canceled)
  4. Publish "episode.canceled" Bus event
  5. Emit [:cyclium, :episode, :canceled] telemetry
  """
  def cancel(episode_id, reason \\ "manual") do
    episode = get!(episode_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # 1. Journal cancellation step
    step_no = next_step_no(episode_id)

    repo().insert!(%EpisodeStep{
      episode_id: episode_id,
      step_no: step_no,
      kind: :episode_failed,
      error_class: "canceled",
      error_detail: %{reason: reason},
      created_at: now
    })

    # 2. Set status to canceled
    {:ok, _} = update_status(episode_id, :canceled)

    # 3. Cancel pending outputs
    from(o in Output,
      where: o.episode_id == ^episode_id and o.status == :proposed
    )
    |> repo().update_all(set: [status: "canceled"])

    # 4. Publish Bus event
    Cyclium.Bus.broadcast("episode.canceled", %{
      episode_id: episode_id,
      actor_id: episode.actor_id,
      reason: reason,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    # 5. Emit telemetry
    :telemetry.execute(
      [:cyclium, :episode, :canceled],
      %{count: 1},
      %{episode_id: episode_id, actor_id: episode.actor_id, reason: reason}
    )

    :ok
  end

  defp next_step_no(episode_id) do
    (from(s in EpisodeStep,
       where: s.episode_id == ^episode_id,
       select: max(s.step_no))
     |> repo().one()) || 0
    |> Kernel.+(1)
  end
end

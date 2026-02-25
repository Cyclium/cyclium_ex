defmodule Cyclium.Episodes do
  @moduledoc """
  Context for episode CRUD operations and lifecycle management.
  """

  import Ecto.Query
  alias Cyclium.Schemas.{Episode, EpisodeStep, EpisodeLog, Output}

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

  def list_steps(episode_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    query = from(s in EpisodeStep, where: s.episode_id == ^episode_id, order_by: [asc: s.step_no])

    query = if limit, do: query |> limit(^limit) |> offset(^offset), else: query

    repo().all(query)
  end

  def count_steps(episode_id) do
    from(s in EpisodeStep, where: s.episode_id == ^episode_id, select: count(s.id))
    |> repo().one()
  end

  def get_log(episode_id) do
    repo().get_by(EpisodeLog, episode_id: episode_id)
  end

  @doc """
  Return the `started_at` of the most recent schedule-triggered episode
  for the given actor and expectation. Returns `nil` if none found.

  Used by schedule timers on actor init to compute correct delay
  after restarts (surviving missed windows).
  """
  def last_schedule_fire(actor_id, expectation_id) do
    from(e in Episode,
      where:
        e.actor_id == ^to_string(actor_id) and
          e.expectation_id == ^to_string(expectation_id) and
          e.trigger_type == :schedule,
      order_by: [desc: e.started_at],
      limit: 1,
      select: e.started_at
    )
    |> repo().one()
  end

  def list_by_status(statuses) when is_list(statuses) do
    from(e in Episode, where: e.status in ^statuses, order_by: [asc: e.started_at])
    |> repo().all()
  end

  @doc """
  List episodes for the given actor ID(s).

  ## Options

    * `:statuses` — list of status atoms to filter by (default: all)
    * `:limit` — max rows to return (default: 50)
    * `:offset` — rows to skip (default: 0)
    * `:order` — `:asc` or `:desc` by `started_at` (default: `:desc`)
    * `:exclude_archived` — when `true`, excludes episodes with a non-nil `archived_at` (default: `false`)

  """
  def list_by_actors(actor_ids, opts \\ []) when is_list(actor_ids) do
    statuses = Keyword.get(opts, :statuses)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    order = Keyword.get(opts, :order, :desc)

    from(e in Episode,
      where: e.actor_id in ^actor_ids,
      order_by: [{^order, e.started_at}],
      limit: ^limit,
      offset: ^offset
    )
    |> maybe_filter_statuses(statuses)
    |> maybe_exclude_archived(opts)
    |> repo().all()
  end

  @doc "Count episodes for the given actor ID(s). Accepts same filter opts as list_by_actors."
  def count_by_actors(actor_ids, opts \\ []) when is_list(actor_ids) do
    statuses = Keyword.get(opts, :statuses)

    from(e in Episode, where: e.actor_id in ^actor_ids, select: count(e.id))
    |> maybe_filter_statuses(statuses)
    |> maybe_exclude_archived(opts)
    |> repo().one()
  end

  defp maybe_filter_statuses(query, nil), do: query
  defp maybe_filter_statuses(query, []), do: query
  defp maybe_filter_statuses(query, statuses), do: where(query, [e], e.status in ^statuses)

  defp maybe_exclude_archived(query, opts) do
    if Keyword.get(opts, :exclude_archived, false) do
      where(query, [e], is_nil(e.archived_at))
    else
      query
    end
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

  defp maybe_set_finished_at(attrs, status)
       when status in [:done, :failed, :partially_failed, :canceled] do
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
       select: max(s.step_no)
     )
     |> repo().one() || 0) + 1
  end
end

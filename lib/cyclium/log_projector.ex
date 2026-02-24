defmodule Cyclium.LogProjector do
  @moduledoc """
  Materializes human-readable logs from episode steps.

  Driven by `log_strategy` on each episode:
  - `:none` — skip entirely
  - `:summary_only` — one-line summary at completion
  - `:timeline` — step-by-step rendered log (default)
  - `:full_debug` — timeline with raw args/results

  Called from `EpisodeRunner.post_converge/2` and available on-demand
  via `project/1`.
  """

  import Ecto.Query

  alias Cyclium.Schemas.{Episode, EpisodeStep, EpisodeLog}

  defp repo, do: Cyclium.repo()

  @doc """
  Project (or update) the log for an episode. Reads steps since
  `last_step_no_rendered` and appends to the log.

  Returns `{:ok, log}` or `:skip` if log_strategy is `:none`.
  """
  def project(episode_id) do
    episode = repo().get!(Episode, episode_id)
    strategy = parse_strategy(episode.log_strategy)

    if strategy == :none do
      :skip
    else
      steps = load_new_steps(episode_id, last_rendered(episode_id))
      content = render_steps(steps, strategy, episode)
      upsert_log(episode_id, content, max_step_no(steps))
    end
  end

  @doc """
  Pure rendering function. Transforms a list of episode steps into
  a human-readable string based on the given strategy.
  """
  def render_steps(steps, strategy, episode \\ nil)

  def render_steps([], :summary_only, episode) do
    actor = if episode, do: episode.actor_id, else: "unknown"
    status = if episode, do: episode.status, else: "unknown"
    "[Summary] Actor #{actor} — #{status}"
  end

  def render_steps(steps, :summary_only, episode) do
    actor = if episode, do: episode.actor_id, else: "unknown"
    status = if episode, do: episode.status, else: "unknown"
    step_count = length(steps)
    "[Summary] Actor #{actor} — #{status} (#{step_count} steps)"
  end

  def render_steps(steps, :timeline, _episode) do
    steps
    |> Enum.map(&render_timeline_step/1)
    |> Enum.join("\n")
  end

  def render_steps(steps, :full_debug, _episode) do
    steps
    |> Enum.map(&render_debug_step/1)
    |> Enum.join("\n")
  end

  def render_steps(_steps, :none, _episode), do: ""

  # --- Timeline rendering ---

  defp render_timeline_step(%EpisodeStep{} = step) do
    time = format_time(step.created_at)
    kind = step.kind

    case kind do
      :tool_call ->
        "[#{time}] #{step.tool_name || "tool"}()"

      :synthesis ->
        "[#{time}] Synthesis requested"

      :observation ->
        "[#{time}] Observation recorded"

      :checkpoint ->
        "[#{time}] Checkpoint saved"

      :output_proposed ->
        "[#{time}] Output proposed: #{step.tool_name || "unknown"}"

      :output_delivered ->
        "[#{time}] Output delivered: #{step.tool_name || "unknown"}"

      :output_failed ->
        "[#{time}] Output failed: #{step.tool_name || "unknown"} (#{step.error_class})"

      :finding_raised ->
        "[#{time}] Finding raised"

      :finding_updated ->
        "[#{time}] Finding updated"

      :finding_cleared ->
        "[#{time}] Finding cleared"

      :approval_requested ->
        "[#{time}] Approval requested"

      :approval_resolved ->
        "[#{time}] Approval resolved"

      :wait_started ->
        "[#{time}] Waiting on external"

      :wait_resolved ->
        "[#{time}] Wait resolved"

      :episode_completed ->
        "[#{time}] Episode completed"

      :episode_failed ->
        error = if step.error_class, do: " (#{step.error_class})", else: ""
        "[#{time}] Episode failed#{error}"

      _ ->
        "[#{time}] #{kind}"
    end
  end

  defp render_debug_step(%EpisodeStep{} = step) do
    base = render_timeline_step(step)
    args = if step.args_redacted, do: "\n  args: #{inspect(step.args_redacted)}", else: ""
    result = if step.result_ref, do: "\n  result: #{inspect(step.result_ref)}", else: ""
    error = if step.error_detail, do: "\n  error: #{inspect(step.error_detail)}", else: ""
    "#{base}#{args}#{result}#{error}"
  end

  defp format_time(nil), do: "??:??"

  defp format_time(%DateTime{} = dt) do
    "#{pad(dt.hour)}:#{pad(dt.minute)}"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  # --- DB operations ---

  defp load_new_steps(episode_id, since_step_no) do
    from(s in EpisodeStep,
      where: s.episode_id == ^episode_id and s.step_no > ^since_step_no,
      order_by: [asc: s.step_no]
    )
    |> repo().all()
  end

  defp last_rendered(episode_id) do
    case repo().get_by(EpisodeLog, episode_id: episode_id) do
      nil -> 0
      log -> log.last_step_no_rendered || 0
    end
  end

  defp max_step_no([]), do: 0
  defp max_step_no(steps), do: steps |> List.last() |> Map.get(:step_no, 0)

  defp upsert_log(episode_id, new_content, last_step_no) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case repo().get_by(EpisodeLog, episode_id: episode_id) do
      nil ->
        %EpisodeLog{}
        |> EpisodeLog.changeset(%{
          episode_id: episode_id,
          format: "markdown",
          content: new_content,
          last_step_no_rendered: last_step_no,
          created_at: now,
          updated_at: now
        })
        |> repo().insert()

      existing ->
        combined =
          case existing.content do
            nil -> new_content
            "" -> new_content
            prev -> prev <> "\n" <> new_content
          end

        existing
        |> EpisodeLog.changeset(%{
          content: combined,
          last_step_no_rendered: last_step_no,
          updated_at: now
        })
        |> repo().update()
    end
  end

  defp parse_strategy(nil), do: :timeline
  defp parse_strategy("none"), do: :none
  defp parse_strategy("summary_only"), do: :summary_only
  defp parse_strategy("timeline"), do: :timeline
  defp parse_strategy("full_debug"), do: :full_debug
  defp parse_strategy(atom) when is_atom(atom), do: atom
  defp parse_strategy(_), do: :timeline
end

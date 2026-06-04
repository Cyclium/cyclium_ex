defmodule Cyclium.Output.Router do
  @moduledoc """
  Deduplicates and dispatches output proposals to adapters.

  ## Flow

    1. Insert `cyclium_outputs` row with dedupe_key unique constraint
    2. If constraint fires → `{:duplicate, existing_output}`
    3. If insert succeeds → resolve adapter from app config, call `deliver/3`
    4. On adapter success → update row to `:delivered`, journal step
    5. On adapter error → update row to `:failed`, journal step
    6. Emit telemetry at each outcome
  """

  alias Cyclium.Schemas.{Output, EpisodeStep}
  alias Cyclium.OutputProposal

  defp repo, do: Cyclium.repo()

  @doc """
  Route an output proposal through dedupe check and adapter dispatch.

  Returns `{:ok, output}`, `{:duplicate, output}`, or `{:error, reason}`.
  """
  @spec route(OutputProposal.t(), map(), map()) ::
          {:ok, %Output{}} | {:duplicate, %Output{}} | {:error, term()}
  def route(%OutputProposal{} = proposal, episode, _episode_ctx) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    dedupe_key = effective_dedupe_key(proposal, episode)

    attrs = %{
      episode_id: episode.id,
      type: to_string(proposal.type),
      dedupe_key: dedupe_key,
      status: :proposed,
      payload_redacted: proposal.payload,
      created_at: now
    }

    changeset = Output.changeset(%Output{}, attrs)

    case repo().insert(changeset) do
      {:ok, output} ->
        deliver_via_adapter(output, proposal, episode)

      {:error, %Ecto.Changeset{} = cs} ->
        if has_unique_error?(cs, :dedupe_key) do
          existing = repo().get_by!(Output, dedupe_key: dedupe_key)
          emit_telemetry(:deduplicated, proposal, %{dedupe_key: dedupe_key})
          {:duplicate, existing}
        else
          {:error, :changeset_invalid}
        end
    end
  end

  # An explicit dedupe_key wins (full strategy control, e.g. Window-bucketed
  # cross-episode dedup). Otherwise derive a re-run-stable key from the episode's
  # own dedupe_key (or id, which is stable across recovery/steal re-runs of the
  # same episode), the output type, and the strategy's logical `:key`.
  defp effective_dedupe_key(%OutputProposal{dedupe_key: dk}, _episode)
       when is_binary(dk) and dk != "",
       # Env-scope a strategy-supplied key too, so a dev node's output isn't
       # deduped against the hosted node's. (The derived branch below already
       # inherits env through episode.dedupe_key.)
       do: Cyclium.Env.scope_key(dk)

  defp effective_dedupe_key(%OutputProposal{key: key, type: type}, episode)
       when is_binary(key) and key != "" do
    base = episode.dedupe_key || episode.id
    digest = :crypto.hash(:sha256, "#{base}|#{type}|#{key}") |> Base.encode16(case: :lower)
    "out:#{digest}"
  end

  # Neither given — no deduplication (matches prior behavior for a missing key).
  defp effective_dedupe_key(%OutputProposal{dedupe_key: dk}, _episode), do: dk

  defp deliver_via_adapter(output, proposal, episode) do
    adapter = Cyclium.Output.Adapter.resolve(proposal.type)

    if is_nil(adapter) do
      mark_failed(output, "no_adapter", %{type: to_string(proposal.type)})
      journal_output_step!(episode, :output_failed, output, "no_adapter")
      emit_telemetry(:failed, proposal, %{reason: :no_adapter})

      Cyclium.Bus.broadcast("output.delivered", %{
        episode_id: episode.id,
        output_id: output.id,
        status: :failed
      })

      {:error, :no_adapter}
    else
      ctx = %{episode_id: episode.id}

      case adapter.deliver(proposal.type, proposal.payload, ctx) do
        {:ok, ref} ->
          {:ok, delivered} = mark_delivered(output, ref)
          journal_output_step!(episode, :output_delivered, output, nil)
          emit_telemetry(:delivered, proposal, %{ref: ref})

          Cyclium.Bus.broadcast("output.delivered", %{
            episode_id: episode.id,
            output_id: output.id
          })

          {:ok, delivered}

        {:error, reason} ->
          error_class = classify_error(reason)
          mark_failed(output, error_class, %{detail: inspect(reason)})
          journal_output_step!(episode, :output_failed, output, error_class)
          emit_telemetry(:failed, proposal, %{reason: reason})
          {:error, reason}
      end
    end
  end

  defp mark_delivered(output, ref) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    output
    |> Output.changeset(%{status: :delivered, delivered_ref: ref, delivered_at: now})
    |> repo().update()
  end

  defp mark_failed(output, error_class, error_detail) do
    output
    |> Output.changeset(%{status: :failed, error_class: error_class, error_detail: error_detail})
    |> repo().update()
  end

  defp journal_output_step!(episode, kind, output, error_class) do
    # EpisodeStep.created_at is :utc_datetime_usec — use full microsecond
    # precision (matching the runner's journal_step!). A :second-truncated value
    # raises ArgumentError on dump, which would crash output journaling.
    step_no = Cyclium.Episodes.next_step_no(episode.id)

    repo().insert!(%EpisodeStep{
      episode_id: episode.id,
      step_no: step_no,
      kind: kind,
      tool_name: output.type,
      side_effect_key: output.dedupe_key,
      error_class: error_class,
      created_at: DateTime.utc_now()
    })
  end

  defp has_unique_error?(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn {_msg, opts} -> opts[:constraint] == :unique end)
  end

  defp classify_error(_), do: "adapter_error"

  defp emit_telemetry(event, proposal, meta) do
    :telemetry.execute(
      [:cyclium, :output, event],
      %{count: 1},
      Map.merge(%{type: to_string(proposal.type), dedupe_key: proposal.dedupe_key}, meta)
    )
  end
end

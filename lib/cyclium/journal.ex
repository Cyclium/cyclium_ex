defmodule Cyclium.Journal do
  @moduledoc """
  Appends steps to an episode's journal: filters each step's data by the
  episode's log strategy, caps stored maps, projects the rendered log and
  broadcasts `episode.step_journaled`.
  """

  require Logger

  alias Cyclium.Schemas.{Episode, EpisodeStep}

  defp repo, do: Cyclium.repo()

  @doc """
  Append a step of `kind` to the episode's journal and return it. `attrs` takes
  the `EpisodeStep` fields a step carries (`:tool_name`, `:args_redacted`,
  `:result_ref`, `:error_class`, `:error_detail`, `:cost_tokens`, `:cost_ms`,
  `:metadata`, ...). A transient database fault is logged and returns an
  unsaved step; any other write error raises.
  """
  @spec append!(Episode.t(), atom(), map()) :: EpisodeStep.t()
  def append!(%Episode{} = episode, kind, attrs) do
    now = DateTime.utc_now()
    step_no = Cyclium.Episodes.next_step_no(episode.id)
    log_strategy = parse_log_strategy(episode.log_strategy)

    {args_redacted, result_ref} =
      filter_step_data(
        log_strategy,
        kind,
        attrs[:tool_name],
        attrs[:args_redacted],
        attrs[:result_ref]
      )

    step = %EpisodeStep{
      episode_id: episode.id,
      step_no: step_no,
      kind: kind,
      tool_name: attrs[:tool_name],
      args_hash: attrs[:args_hash],
      args_redacted: cap_stored_map(args_redacted),
      result_ref: cap_stored_map(result_ref),
      error_class: attrs[:error_class],
      error_detail: cap_stored_map(attrs[:error_detail]),
      side_effect_key: attrs[:side_effect_key],
      cost_tokens: attrs[:cost_tokens],
      cost_ms: attrs[:cost_ms],
      metadata: attrs[:metadata],
      created_at: now
    }

    inserted = insert_step(step)

    # Incrementally project the log after each step (append-only), unless the
    # expectation opted out via `render_log: false` — an actor can keep full step
    # journaling for a chat UI while skipping the redundant rendered log.
    if render_log?(episode), do: Cyclium.LogProjector.project(episode.id)

    Cyclium.Bus.broadcast("episode.step_journaled", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      conversation_id: episode.conversation_id,
      step_no: step_no,
      kind: kind,
      tool_name: attrs[:tool_name],
      error_class: attrs[:error_class],
      cost_tokens: attrs[:cost_tokens]
    })

    inserted
  end

  # Insert a journal step. A transient DB-layer fault — e.g. an intermittent Tds
  # (SQL Server) parameter-encoding / connection blip on a single INSERT, not
  # caused by any value the actor feeds in — must NOT crash an episode that is
  # otherwise progressing. Degrade gracefully: log loudly, emit a metric so a
  # spike is visible, and continue with an in-memory step struct so the loop's
  # step bookkeeping still holds. The only loss is that one journal row + its
  # rendered-log/bus projection; the episode still completes and the user still
  # gets an answer. Non-transient errors (a real schema/encoding bug) still
  # raise — we don't want to silently mask those.
  defp insert_step(step) do
    repo().insert!(step)
  rescue
    e ->
      unless transient_db_error?(e), do: reraise(e, __STACKTRACE__)

      Logger.error("cyclium: step journal write failed; continuing un-journaled",
        episode_id: step.episode_id,
        kind: step.kind,
        error: inspect(e.__struct__)
      )

      :telemetry.execute(
        [:cyclium, :step, :journal_dropped],
        %{count: 1},
        %{episode_id: step.episode_id, kind: step.kind, error: inspect(e.__struct__)}
      )

      # In-memory fallback so downstream step bookkeeping (ids, step_no) holds.
      %{step | id: Ecto.UUID.generate()}
  end

  # Match transient DB-layer faults by struct so we don't hard-depend on the
  # optional Tds driver being compiled in (referencing `Tds.Error` directly would
  # warn when SQL Server isn't a configured adapter). Tds.Error (SQL Server) and
  # DBConnection.ConnectionError are the transient connection/encoding faults we
  # degrade on; everything else (e.g. a real constraint/cast error) re-raises.
  defp transient_db_error?(%DBConnection.ConnectionError{}), do: true
  defp transient_db_error?(%{__struct__: Tds.Error}), do: true
  defp transient_db_error?(_), do: false

  # Runaway guard on the JSON size of a stored step `:map` (args_redacted /
  # result_ref / error_detail) — NOT a driver hard limit. The columns are
  # `nvarchar(max)` and Tds (2.3.x) PLP-chunks any nvarchar parameter whose
  # UTF-16 form exceeds 8000 bytes, so larger values round-trip intact — the
  # earlier "~4000-byte driver truncation" was a misdiagnosis of this app-level
  # cap firing (verified against Tds.Types.encode_data/3, which routes
  # `value_size > 8000` through encode_plp/1). The true ceiling is the
  # `nvarchar(max)`/PLP limit of 2 GB (~1.07e9 UTF-16 chars); we deliberately
  # stop far short because every reader of the row (post-converge AND transcript
  # rebuild) JSON-decodes it into memory, so an unbounded blob is a read-cost
  # risk, not a correctness one. At 1_000_000 (~2 MB/field) every realistic
  # approval plan and tool result survives journaling — enough to be resumed and
  # rebuilt into a transcript — while a pathological payload still degrades to a
  # visible `_truncated` marker instead of wedging readers. Full-fidelity
  # storage for the pathological case (chunk-and-reassemble, or an out-of-row
  # blob) remains the longer-term fix.
  @map_field_max_chars 1_000_000

  defp cap_stored_map(nil), do: nil

  defp cap_stored_map(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} ->
        if String.length(json) <= @map_field_max_chars do
          map
        else
          # Preserve the shape but truncate string leaves; if it still doesn't
          # fit (e.g. one dominant string + other fields), fall back to a
          # compact, always-valid-JSON marker so the row is never stored corrupt.
          truncated = truncate_map_leaves(map)

          if map_char_size(truncated) <= @map_field_max_chars do
            truncated
          else
            %{"_truncated" => true, "preview" => slice_chars(json, @map_field_max_chars - 64)}
          end
        end

      {:error, _} ->
        # A leaf isn't JSON-encodable (e.g. a raw Ecto struct that a strategy
        # leaked into its context payload). The Tds adapter would `Jason.encode!`
        # this same `:map` parameter at insert time and crash the episode, so
        # degrade to an inspect-based preview marker instead of passing it
        # through. Defense in depth — strategies should hand JSON-safe maps.
        preview =
          map
          |> inspect(limit: :infinity, printable_limit: :infinity)
          |> slice_chars(@map_field_max_chars - 64)

        %{"_unencodable" => true, "preview" => preview}
    end
  end

  defp cap_stored_map(other), do: other

  # JSON-encoded length in characters (≈ UTF-16 code units for the BMP). Returns
  # 0 if the value isn't JSON-encodable — callers that must distinguish an encode
  # failure from an empty map handle `Jason.encode/1` directly (see cap_stored_map/1).
  defp map_char_size(map) do
    case Jason.encode(map) do
      {:ok, json} -> String.length(json)
      _ -> 0
    end
  end

  defp truncate_map_leaves(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, truncate_leaf(v)} end)
  end

  defp truncate_leaf(v) when is_binary(v), do: slice_chars(v, @map_field_max_chars)
  # Structs (e.g. DateTime) are maps but aren't Enumerable — treat them as leaves
  # rather than recursing into them. Must come before the is_map/1 clause.
  defp truncate_leaf(v) when is_struct(v), do: v
  defp truncate_leaf(v) when is_map(v), do: truncate_map_leaves(v)
  defp truncate_leaf(v) when is_list(v), do: Enum.map(v, &truncate_leaf/1)
  defp truncate_leaf(v), do: v

  defp slice_chars(s, max) when is_binary(s) do
    if String.length(s) <= max, do: s, else: String.slice(s, 0, max) <> "…[truncated]"
  end

  # Size cap for stored synthesis responses. Larger than this gets truncated
  # on a per-field basis (content text) to keep DB rows reasonable.
  @synthesis_result_max_bytes 50_000
  @synthesis_result_summary_bytes 2_000

  # full_debug: store everything, but redact prompt content from synthesis steps
  # and cap overly-large synthesis responses to prevent DB bloat.
  defp filter_step_data(:full_debug, :synthesis, _tool_name, args, result) do
    {redact_synthesis_args(args), cap_synthesis_result(result, @synthesis_result_max_bytes)}
  end

  defp filter_step_data(:full_debug, _kind, _tool_name, args, result), do: {args, result}

  # timeline: store tool name + summary only, not full payloads
  defp filter_step_data(:timeline, :tool_call, tool_name, _args, result) do
    {%{tool: tool_name}, summarize_result(result)}
  end

  defp filter_step_data(:timeline, :synthesis, _tool_name, args, result) do
    {redact_synthesis_args(summarize_result(args)),
     cap_synthesis_result(result, @synthesis_result_summary_bytes)}
  end

  defp filter_step_data(:timeline, :observation, _tool_name, _args, result) do
    {nil, summarize_result(result)}
  end

  # timeline: pass through for non-data steps (findings, completion, errors)
  defp filter_step_data(:timeline, _kind, _tool_name, args, result), do: {args, result}

  # none / summary_only: omit args and results entirely
  defp filter_step_data(strategy, _kind, _tool_name, _args, _result)
       when strategy in [:none, :summary_only] do
    {nil, nil}
  end

  @synthesis_redact_keys ~w(system_prompt system user user_message prompt message)

  defp redact_synthesis_args(nil), do: nil

  defp redact_synthesis_args(args) when is_map(args) and not is_struct(args) do
    Enum.reduce(args, args, fn {k, _v}, acc ->
      key_str = to_string(k)

      if key_str in @synthesis_redact_keys do
        Map.put(acc, k, "[REDACTED]")
      else
        case Map.get(acc, k) do
          v when is_map(v) and not is_struct(v) -> Map.put(acc, k, redact_synthesis_args(v))
          _ -> acc
        end
      end
    end)
  end

  # Structs (e.g. Cyclium.Intent.GoalSpec) are maps but don't implement
  # Enumerable, so they must not be walked with Enum.reduce — pass through.
  defp redact_synthesis_args(args), do: args

  defp summarize_result(nil), do: nil

  defp summarize_result(result) when is_map(result) and not is_struct(result) do
    # Keep scalar values and counts, drop nested data
    result
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(v) and byte_size(v) <= 200 -> Map.put(acc, k, v)
      {k, v}, acc when is_number(v) or is_boolean(v) or is_atom(v) -> Map.put(acc, k, v)
      {k, v}, acc when is_list(v) -> Map.put(acc, k, %{count: length(v)})
      {k, v}, acc when is_map(v) -> Map.put(acc, k, %{keys: Map.keys(v)})
      _, acc -> acc
    end)
  end

  defp summarize_result(result), do: result

  defp parse_log_strategy(nil), do: :timeline
  defp parse_log_strategy("none"), do: :none
  defp parse_log_strategy("summary_only"), do: :summary_only
  defp parse_log_strategy("timeline"), do: :timeline
  defp parse_log_strategy("full_debug"), do: :full_debug
  defp parse_log_strategy(atom) when is_atom(atom), do: atom
  defp parse_log_strategy(_), do: :timeline

  # Whether to materialize the rendered log for this episode. Resolved from the
  # expectation's `render_log` (stored in persistent_term at actor boot), keyed by
  # the episode's actor/expectation. Defaults to true when no entry exists (e.g.
  # the actor isn't registered on this node), so logs render unless opted out.
  @spec render_log?(Episode.t()) :: boolean()
  defp render_log?(%Episode{actor_id: actor_id, expectation_id: exp_id}) do
    with actor_key when is_atom(actor_key) <- existing_atom(actor_id),
         exp_key when is_atom(exp_key) <- existing_atom(exp_id) do
      :persistent_term.get({:cyclium_expectation_render_log, actor_key, exp_key}, true)
    end
  end

  defp existing_atom(value) when is_atom(value), do: value

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(_), do: nil

  # Truncate a synthesis result's content blocks so the stored map stays
  # under roughly `max_bytes`. Preserves shape (content blocks, stop_reason,
  # usage) so the UI can render it normally. Each text block is cut
  # individually and annotated with a truncation marker.
  defp cap_synthesis_result(result, max_bytes) when is_map(result) do
    content = result[:content] || result["content"]

    if is_list(content) do
      # Share the byte budget across all text blocks
      text_blocks = Enum.count(content, &text_block?/1)
      per_block = if text_blocks > 0, do: div(max_bytes, text_blocks), else: max_bytes

      capped =
        Enum.map(content, fn block ->
          if text_block?(block) do
            cap_text_block(block, per_block)
          else
            # Non-text blocks (tool_use, tool_result) kept as-is — they're
            # structured data the agent may need, not free text.
            block
          end
        end)

      result
      |> Map.put(:content, capped)
      |> Map.put("content", capped)
    else
      result
    end
  end

  defp cap_synthesis_result(result, _), do: result

  defp text_block?(%{"type" => "text"}), do: true
  defp text_block?(%{type: :text}), do: true
  defp text_block?(%{type: "text"}), do: true
  defp text_block?(_), do: false

  defp cap_text_block(block, max_bytes) do
    text = block["text"] || block[:text] || ""

    cond do
      not is_binary(text) ->
        block

      byte_size(text) <= max_bytes ->
        block

      true ->
        truncated =
          String.slice(text, 0, max_bytes) <>
            "\n\n... [truncated: original #{byte_size(text)} bytes]"

        block
        |> Map.put("text", truncated)
        |> Map.put(:text, truncated)
    end
  end
end

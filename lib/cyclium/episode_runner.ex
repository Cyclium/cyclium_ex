defmodule Cyclium.EpisodeRunner do
  @moduledoc """
  Executes the episode loop: calls strategy callbacks, enforces budgets,
  journals steps, and runs the post-converge sequence.

  The post-converge pipeline (Phase 3) persists findings, delivers outputs
  via `Cyclium.Output.Router`, and computes final episode status from
  delivery outcomes.
  """

  require Logger

  alias Cyclium.DryRun.FindingPrefixer
  alias Cyclium.Schemas.{Episode, EpisodeStep}

  defp repo, do: Cyclium.repo()

  def execute_loop(%Episode{} = episode, strategy, state, opts \\ []) do
    if synth = opts[:synthesizer], do: Process.put(:cyclium_synthesizer, synth)

    Logger.metadata(
      cyclium_actor_id: episode.actor_id,
      cyclium_episode_id: episode.id,
      cyclium_expectation_id: episode.expectation_id
    )

    deadline_ref =
      Process.send_after(self(), :budget_wall_exceeded, episode.budget["max_wall_ms"] || 120_000)

    try do
      do_loop(episode, strategy, state, DateTime.utc_now())
    after
      Process.cancel_timer(deadline_ref)
    end
  end

  defp do_loop(episode, strategy, state, started_at) do
    receive do
      :budget_wall_exceeded ->
        elapsed = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

        journal_step!(episode, :episode_failed, %{
          error_class: "budget_exceeded",
          error_detail: %{
            kind: "wall_time",
            used_ms: elapsed,
            max_ms: episode.budget["max_wall_ms"]
          }
        })

        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "budget_exceeded")

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        {:error, :budget_exceeded}

      {:EXIT, _from, reason} ->
        Logger.warning(
          "Episode task received EXIT (#{inspect(reason)}), terminating episode",
          cyclium_episode_id: episode.id
        )

        journal_step!(episode, :episode_failed, %{
          error_class: "process_terminated",
          error_detail: %{exit_reason: inspect(reason)}
        })

        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "process_terminated")

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        {:error, :process_terminated}
    after
      0 -> :ok
    end

    with :ok <- check_budget(episode),
         :ok <- check_loop(episode) do
      increment_turn(episode)
      episode_ctx = build_episode_ctx(episode)

      step_action = strategy.next_step(state, episode_ctx)
      record_step_kind(step_action)

      case step_action do
        :done ->
          journal_step!(episode, :episode_completed, %{})
          Cyclium.Episodes.update_status(episode.id, :done)
          {:ok, state}

        :converge ->
          run_converge(episode, strategy, state)

        {:tool_call, capability, action, args} ->
          :telemetry.execute([:cyclium, :step, :tool_call], %{count: 1}, %{
            tool: capability,
            action: action,
            episode_id: episode.id
          })

          tool_name = "#{capability}.#{action}"

          case dry_run_tool_override(episode, tool_name) do
            {:mock, mock_result} ->
              step =
                journal_step!(episode, :tool_call, %{
                  tool_name: tool_name,
                  args_redacted: args,
                  result_ref: %{"_dry_run" => true, "mock" => inspect(mock_result)}
                })

              handle_strategy_result(
                episode,
                strategy,
                state,
                step,
                {:ok, mock_result},
                started_at
              )

            :real ->
              case Cyclium.ToolExec.call(capability, action, args, %{episode: episode}) do
                {:ok, result, cost, redacted} ->
                  step =
                    journal_step!(episode, :tool_call, %{
                      tool_name: tool_name,
                      args_redacted: redacted.args_redacted,
                      result_ref: redacted.result_redacted,
                      cost_tokens: cost
                    })

                  increment_budget(episode, cost)

                  handle_strategy_result(
                    episode,
                    strategy,
                    state,
                    step,
                    {:ok, result},
                    started_at
                  )

                {:error, _reason} = err ->
                  step =
                    journal_step!(episode, :tool_call, %{
                      tool_name: tool_name,
                      args_redacted: args,
                      error_class: "tool_error"
                    })

                  handle_strategy_result(episode, strategy, state, step, err, started_at)
              end
          end

        {:synthesize, prompt_ctx} ->
          :telemetry.execute([:cyclium, :step, :synthesis], %{count: 1}, %{episode_id: episode.id})

          {prompt_for_synth, prompt_for_storage} = split_transient(prompt_ctx)

          case dry_run_synthesis_override(episode) do
            {:mock, mock_result} ->
              step =
                journal_step!(episode, :synthesis, %{
                  args_redacted: prompt_for_storage,
                  result_ref: %{"_dry_run" => true}
                })

              handle_strategy_result(
                episode,
                strategy,
                state,
                step,
                {:ok, mock_result},
                started_at
              )

            :real ->
              case resolve_synthesizer() do
                nil ->
                  Logger.warning(
                    "No :synthesizer configured — :synthesize step will pass prompt_ctx through as-is",
                    cyclium_episode_id: episode.id
                  )

                  step = journal_step!(episode, :synthesis, %{args_redacted: prompt_for_storage})

                  handle_strategy_result(
                    episode,
                    strategy,
                    state,
                    step,
                    {:ok, prompt_for_synth},
                    started_at
                  )

                synthesizer ->
                  episode_ctx = build_episode_ctx(episode)

                  case synthesizer.synthesize(prompt_for_synth, episode_ctx) do
                    {:ok, result} ->
                      token_cost =
                        extract_api_token_cost(result) ||
                          fallback_estimate_tokens(synthesizer, prompt_for_synth)

                      step =
                        journal_step!(episode, :synthesis, %{
                          args_redacted: prompt_for_storage,
                          cost_tokens: token_cost
                        })

                      increment_budget(episode, token_cost)

                      handle_strategy_result(
                        episode,
                        strategy,
                        state,
                        step,
                        {:ok, result},
                        started_at
                      )

                    {:error, error_class, detail} ->
                      step =
                        journal_step!(episode, :synthesis, %{
                          args_redacted: prompt_for_storage,
                          error_class: to_string(error_class),
                          error_detail: %{reason: inspect(detail)}
                        })

                      handle_strategy_result(
                        episode,
                        strategy,
                        state,
                        step,
                        {:error, {error_class, detail}},
                        started_at
                      )
                  end
              end
          end

        {:observe, data} ->
          :telemetry.execute([:cyclium, :step, :observation], %{count: 1}, %{
            actor_id: episode.actor_id,
            episode_id: episode.id
          })

          journal_step!(episode, :observation, %{result_ref: data})

          case strategy.handle_result(state, %EpisodeStep{kind: :observation}, {:ok, data}) do
            {:ok, new_state} -> do_loop(episode, strategy, new_state, started_at)
            {:abort, reason} -> abort_episode(episode, reason)
          end

        {:checkpoint, phase_name} ->
          save_checkpoint(episode, phase_name, state)
          do_loop(episode, strategy, state, started_at)

        {:output, type, payload} ->
          journal_step!(episode, :output_proposed, %{
            tool_name: to_string(type),
            args_redacted: payload
          })

          do_loop(episode, strategy, state, started_at)

        {:approval, request} ->
          journal_step!(episode, :approval_requested, %{args_redacted: request})
          Cyclium.Episodes.update_status(episode.id, :blocked)
          {:blocked, state}

        {:wait, external_ref} ->
          journal_step!(episode, :wait_started, %{result_ref: external_ref})
          Cyclium.Episodes.update_status(episode.id, :blocked)
          {:blocked, state}
      end
    else
      {:error, :budget_exceeded} = err ->
        current = Cyclium.Episodes.get!(episode.id)

        journal_step!(episode, :episode_failed, %{
          error_class: "budget_exceeded",
          error_detail: %{
            turns_used: current.turns_used,
            max_turns: (current.budget || %{})["max_turns"],
            tokens_used: current.tokens_used,
            max_tokens: (current.budget || %{})["max_tokens"]
          }
        })

        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "budget_exceeded")

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        err

      {:error, :loop_detected} = err ->
        history = Process.get(:cyclium_step_history, [])

        journal_step!(episode, :episode_failed, %{
          error_class: "loop_detected",
          error_detail: %{
            step_fingerprints: history,
            message: "Repeating step cycle detected — strategy may be stuck"
          }
        })

        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "loop_detected")

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        err
    end
  end

  defp handle_strategy_result(episode, strategy, state, step, result, started_at) do
    case strategy.handle_result(state, step, result) do
      {:ok, new_state} -> do_loop(episode, strategy, new_state, started_at)
      {:retry, new_state} -> do_loop(episode, strategy, new_state, started_at)
      {:abort, reason} -> abort_episode(episode, reason)
    end
  end

  defp run_converge(episode, strategy, state) do
    episode_ctx = build_episode_ctx(episode)

    case strategy.converge(state, episode_ctx) do
      {:ok, converge_result} ->
        post_converge(episode, converge_result)

      {:partial, converge_result, _failures} ->
        post_converge(episode, converge_result)
    end
  end

  defp post_converge(episode, converge_result) do
    dry_run? = episode.mode == "dry_run"
    findings = converge_result.findings || []

    # Step 1+2+3: Persist findings (journaled in dry run; optionally persisted with prefix)
    if dry_run? do
      journal_dry_run_findings(episode, findings)
      maybe_persist_dry_run_findings(episode, findings)
    else
      persist_findings(episode, findings)
    end

    # Step 4: Deliver outputs via OutputRouter (skipped in dry run)
    output_results =
      if dry_run? do
        journal_dry_run_outputs(episode, converge_result.outputs || [])
      else
        (converge_result.outputs || [])
        |> Enum.map(fn proposal ->
          Cyclium.Output.Router.route(proposal, episode, build_episode_ctx(episode))
        end)
      end

    # Step 5: Compute final episode status from delivery outcomes
    final_status = compute_episode_status(output_results)

    # Step 6: Journal and set episode status
    step_kind =
      if final_status in [:done, :partially_failed], do: :episode_completed, else: :episode_failed

    journal_step!(episode, step_kind, %{
      result_ref: %{
        summary: converge_result.summary,
        classification: converge_result.classification,
        confidence: converge_result.confidence,
        outputs_delivered: count_outcomes(output_results, :ok),
        outputs_failed: count_outcomes(output_results, :error),
        outputs_duped: count_outcomes(output_results, :duplicate)
      },
      error_class: if(final_status == :failed, do: "all_outputs_failed")
    })

    Cyclium.Episodes.update_status(episode.id, final_status,
      summary: converge_result.summary,
      classification: converge_result.classification,
      confidence: converge_result.confidence
    )

    # Step 7: Service levels and adaptive budget tracking
    maybe_record_service_levels(episode, final_status)
    maybe_record_adaptive_budget(episode)

    # Step 8: Bus event + telemetry
    bus_event = if final_status == :failed, do: "episode.failed", else: "episode.completed"

    Cyclium.Bus.broadcast(bus_event, %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: final_status,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    :telemetry.execute(
      [:cyclium, :episode, if(final_status == :failed, do: :failed, else: :completed)],
      %{count: 1},
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        output_count: length(converge_result.outputs || []),
        finding_count: length(converge_result.findings || [])
      }
    )

    # Step 9: Interactive conversation hook (goal evaluation, field collection)
    maybe_run_conversation_hook(episode, converge_result)

    if final_status == :failed do
      {:error, :all_outputs_failed}
    else
      {:ok, converge_result}
    end
  end

  defp maybe_run_conversation_hook(%{conversation_id: conv_id} = episode, converge_result)
       when is_binary(conv_id) and conv_id != "" do
    Cyclium.Intent.ConversationHook.after_converge(
      conv_id,
      converge_result,
      episode.tokens_used || 0
    )
  rescue
    e ->
      Logger.warning("ConversationHook failed: #{inspect(e)}",
        cyclium_episode_id: episode.id
      )
  end

  defp maybe_run_conversation_hook(_episode, _converge_result), do: :ok

  defp persist_findings(episode, findings) do
    Enum.each(findings, fn action ->
      case Cyclium.Findings.persist_finding(action, episode) do
        {:ok, finding} ->
          bus_event = finding_bus_event(action)

          Cyclium.Bus.broadcast(bus_event, %{
            episode_id: episode.id,
            finding_id: finding.id,
            finding_key: finding.finding_key,
            actor_id: finding.actor_id
          })

          journal_finding_step!(episode, action, finding)

        :ok ->
          # Idempotent clear — nothing to broadcast
          :ok

        {:error, reason} ->
          Logger.warning("Failed to persist finding: #{inspect(reason)}",
            finding_action: inspect(action)
          )
      end
    end)
  end

  defp compute_episode_status(output_results) do
    successes =
      Enum.count(output_results, &match?({:ok, _}, &1)) +
        Enum.count(output_results, &match?({:duplicate, _}, &1))

    failures = Enum.count(output_results, &match?({:error, _}, &1))
    total = length(output_results)

    cond do
      total == 0 -> :done
      failures == 0 -> :done
      successes == 0 -> :failed
      true -> :partially_failed
    end
  end

  defp count_outcomes(results, :ok), do: Enum.count(results, &match?({:ok, _}, &1))
  defp count_outcomes(results, :error), do: Enum.count(results, &match?({:error, _}, &1))
  defp count_outcomes(results, :duplicate), do: Enum.count(results, &match?({:duplicate, _}, &1))

  defp finding_bus_event({:raise, _}), do: "finding.raised"
  defp finding_bus_event({:update, _, _}), do: "finding.updated"
  defp finding_bus_event({:clear, _}), do: "finding.cleared"
  defp finding_bus_event({:clear, _, _}), do: "finding.cleared"

  defp journal_finding_step!(episode, action, finding) do
    kind =
      case action do
        {:raise, _} -> :finding_raised
        {:update, _, _} -> :finding_updated
        {:clear, _} -> :finding_cleared
        {:clear, _, _} -> :finding_cleared
      end

    journal_step!(episode, kind, %{
      result_ref: %{finding_id: finding.id, finding_key: finding.finding_key}
    })
  end

  defp abort_episode(episode, reason) do
    journal_step!(episode, :episode_failed, %{
      error_class: "abort",
      error_detail: %{reason: inspect(reason)}
    })

    Cyclium.Episodes.update_status(episode.id, :failed, error_class: "abort")

    Cyclium.Bus.broadcast("episode.failed", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: :failed,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    {:error, reason}
  end

  defp check_budget(%Episode{} = episode) do
    episode = Cyclium.Episodes.get!(episode.id)
    budget = episode.budget || %{}
    max_turns = budget["max_turns"] || 50
    max_tokens = budget["max_tokens"] || 100_000

    cond do
      max_turns > 0 and episode.turns_used >= max_turns -> {:error, :budget_exceeded}
      max_tokens > 0 and episode.tokens_used >= max_tokens -> {:error, :budget_exceeded}
      true -> :ok
    end
  end

  # Detect repeating cycles of any length (1, 2, 3, ...) in the step history.
  # e.g. [A, B, A, B] is a 2-step cycle repeated twice → loop.
  # e.g. [A, A, A] is a 1-step cycle repeated 3 times → loop.
  # We require 2 full repetitions of the cycle to trigger.
  @max_history 8

  defp check_loop(episode) do
    history = Process.get(:cyclium_step_history, [])

    if repeating_cycle?(history) do
      Logger.error(
        "Loop detected: repeating step cycle in episode",
        cyclium_episode_id: episode.id
      )

      {:error, :loop_detected}
    else
      :ok
    end
  end

  defp repeating_cycle?(history) when length(history) < 3, do: false

  defp repeating_cycle?(history) do
    # Check for cycles of length 1, 2, 3, ... up to half the history
    max_cycle = div(length(history), 2)

    Enum.any?(1..max_cycle, fn cycle_len ->
      cycle = Enum.take(history, cycle_len)
      repetitions = div(length(history), cycle_len)

      repetitions >= 2 and
        Enum.chunk_every(Enum.take(history, cycle_len * repetitions), cycle_len)
        |> Enum.all?(&(&1 == cycle))
    end)
  end

  # Track by content hash — same step kind with different data is fine,
  # only identical actions (same kind + same args) indicate a loop.
  defp record_step_kind(step_action) do
    fingerprint = :erlang.phash2(step_action)

    history = Process.get(:cyclium_step_history, [])
    Process.put(:cyclium_step_history, [fingerprint | Enum.take(history, @max_history - 1)])
  end

  defp increment_turn(%Episode{} = episode) do
    import Ecto.Query

    from(e in Episode, where: e.id == ^episode.id)
    |> repo().update_all(inc: [turns_used: 1])
  end

  # Extract actual input + output token counts from the API response.
  # Returns nil if no usage data is present (e.g. non-API synthesizer).
  defp extract_api_token_cost(result) do
    usage = result[:usage] || result["usage"]

    case usage do
      %{} = u ->
        input = u[:input_tokens] || u["input_tokens"] || 0
        output = u[:output_tokens] || u["output_tokens"] || 0
        total = input + output
        if total > 0, do: total, else: nil

      _ ->
        nil
    end
  end

  defp fallback_estimate_tokens(synthesizer, prompt_ctx) do
    if function_exported?(synthesizer, :estimate_tokens, 1),
      do: synthesizer.estimate_tokens(prompt_ctx),
      else: 0
  end

  defp increment_budget(%Episode{} = episode, token_cost) when is_integer(token_cost) do
    import Ecto.Query

    from(e in Episode, where: e.id == ^episode.id)
    |> repo().update_all(inc: [tokens_used: token_cost])
  end

  defp save_checkpoint(episode, phase_name, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    step_count = count_checkpoints(episode.id)

    repo().insert!(%Cyclium.Schemas.EpisodeCheckpoint{
      episode_id: episode.id,
      checkpoint_no: step_count + 1,
      phase: phase_name,
      schema_version: 1,
      state: state,
      created_at: now
    })
  end

  defp count_checkpoints(episode_id) do
    import Ecto.Query

    from(c in Cyclium.Schemas.EpisodeCheckpoint,
      where: c.episode_id == ^episode_id,
      select: count()
    )
    |> repo().one()
  end

  defp journal_step!(%Episode{} = episode, kind, attrs) do
    now = DateTime.utc_now()
    step_no = next_step_no(episode.id)
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
      args_redacted: args_redacted,
      result_ref: result_ref,
      error_class: attrs[:error_class],
      error_detail: attrs[:error_detail],
      side_effect_key: attrs[:side_effect_key],
      cost_tokens: attrs[:cost_tokens],
      cost_ms: attrs[:cost_ms],
      created_at: now
    }

    inserted = repo().insert!(step)

    # Incrementally project the log after each step (append-only)
    Cyclium.LogProjector.project(episode.id)

    Cyclium.Bus.broadcast("episode.step_journaled", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      step_no: step_no,
      kind: kind
    })

    inserted
  end

  # full_debug: store everything, but redact prompt content from synthesis steps
  defp filter_step_data(:full_debug, :synthesis, _tool_name, args, result) do
    {redact_synthesis_args(args), result}
  end

  defp filter_step_data(:full_debug, _kind, _tool_name, args, result), do: {args, result}

  # timeline: store tool name + summary only, not full payloads
  defp filter_step_data(:timeline, :tool_call, tool_name, _args, result) do
    {%{tool: tool_name}, summarize_result(result)}
  end

  defp filter_step_data(:timeline, :synthesis, _tool_name, args, result) do
    {redact_synthesis_args(summarize_result(args)), summarize_result(result)}
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

  # Splits a synthesis payload into {full_for_synthesizer, stripped_for_storage}.
  # Keys listed under :__transient__ are passed to the synthesizer but omitted
  # from the persisted args_redacted. The :__transient__ key itself is always removed.
  defp split_transient(prompt_ctx) when is_map(prompt_ctx) do
    {transient_keys, full} = Map.pop(prompt_ctx, :__transient__, [])
    storage = Map.drop(full, transient_keys)
    {full, storage}
  end

  defp split_transient(prompt_ctx), do: {prompt_ctx, prompt_ctx}

  defp redact_synthesis_args(nil), do: nil

  defp redact_synthesis_args(args) when is_map(args) do
    Enum.reduce(args, args, fn {k, _v}, acc ->
      key_str = to_string(k)

      if key_str in @synthesis_redact_keys do
        Map.put(acc, k, "[REDACTED]")
      else
        case Map.get(acc, k) do
          v when is_map(v) -> Map.put(acc, k, redact_synthesis_args(v))
          _ -> acc
        end
      end
    end)
  end

  defp redact_synthesis_args(args), do: args

  defp summarize_result(nil), do: nil

  defp summarize_result(result) when is_map(result) do
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

  defp next_step_no(episode_id) do
    import Ecto.Query

    (from(s in EpisodeStep, where: s.episode_id == ^episode_id, select: max(s.step_no))
     |> repo().one() || 0) + 1
  end

  defp resolve_synthesizer do
    Process.get(:cyclium_synthesizer) || Application.get_env(:cyclium, :synthesizer)
  end

  defp build_episode_ctx(%Episode{} = episode) do
    %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      expectation_id: episode.expectation_id,
      budget: episode.budget,
      turns_used: episode.turns_used,
      tokens_used: episode.tokens_used
    }
  end

  # --- Dry run helpers ---

  defp dry_run_tool_override(%{mode: "dry_run", dry_run_opts: opts}, tool_name)
       when is_map(opts) do
    overrides = Map.get(opts, "tool_overrides", %{})

    case Map.get(overrides, tool_name) do
      nil -> :real
      mock -> {:mock, mock}
    end
  end

  defp dry_run_tool_override(_episode, _tool_name), do: :real

  defp dry_run_synthesis_override(%{mode: "dry_run", dry_run_opts: opts}) when is_map(opts) do
    case Map.get(opts, "synthesis_override") do
      nil -> :real
      mock -> {:mock, mock}
    end
  end

  defp dry_run_synthesis_override(_episode), do: :real

  defp journal_dry_run_findings(episode, findings) do
    Enum.each(findings, fn action ->
      kind =
        case action do
          {:raise, _} -> :finding_raised
          {:update, _, _} -> :finding_updated
          {:clear, _} -> :finding_cleared
          {:clear, _, _} -> :finding_cleared
        end

      detail =
        case action do
          {:raise, attrs} -> attrs
          {:update, _key, attrs} -> attrs
          {:clear, key} -> %{finding_key: key}
          {:clear, key, _} -> %{finding_key: key}
        end

      journal_step!(episode, kind, %{
        result_ref: Map.merge(detail, %{"_dry_run" => true})
      })
    end)
  end

  defp maybe_persist_dry_run_findings(episode, findings) do
    case FindingPrefixer.persist_prefix(episode) do
      nil -> :ok
      prefix -> persist_findings(episode, FindingPrefixer.prefix_actions(findings, prefix))
    end
  end

  defp journal_dry_run_outputs(episode, outputs) do
    Enum.map(outputs, fn proposal ->
      journal_step!(episode, :output_proposed, %{
        result_ref: %{"_dry_run" => true, "proposal" => inspect(proposal)}
      })

      {:ok, :dry_run_skipped}
    end)
  end

  defp maybe_record_service_levels(episode, final_status) do
    duration_ms =
      if episode.started_at do
        DateTime.diff(DateTime.utc_now(), episode.started_at, :millisecond)
      else
        0
      end

    success = final_status in [:done, :partially_failed]

    Cyclium.ServiceLevels.record(
      episode.actor_id,
      episode.expectation_id,
      %{duration_ms: duration_ms, success: success}
    )

    case Cyclium.ServiceLevels.check(episode.actor_id, episode.expectation_id) do
      :ok ->
        :ok

      {:breach, details} ->
        :telemetry.execute(
          [:cyclium, :service_levels, :breach],
          %{count: 1},
          Map.merge(details, %{
            actor_id: episode.actor_id,
            expectation_id: episode.expectation_id
          })
        )

        Cyclium.Bus.broadcast("service_levels.breach", %{
          actor_id: episode.actor_id,
          expectation_id: episode.expectation_id,
          breach: details
        })
    end
  rescue
    _ -> :ok
  end

  defp maybe_record_adaptive_budget(episode) do
    wall_ms =
      if episode.started_at do
        DateTime.diff(DateTime.utc_now(), episode.started_at, :millisecond)
      else
        0
      end

    # Extract turns and tokens from episode steps count (approximate)
    turns = Cyclium.Episodes.count_steps(episode.id) || 0

    Cyclium.AdaptiveBudget.record(
      episode.actor_id,
      episode.expectation_id,
      %{turns_used: turns, tokens_used: 0, wall_ms: wall_ms}
    )
  rescue
    _ -> :ok
  end
end

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
    # Fence (ownership generation) we acquired, for the post-converge re-check.
    Process.put(:cyclium_claim_fence, opts[:claim_fence])

    Logger.metadata(
      cyclium_actor_id: episode.actor_id,
      cyclium_episode_id: episode.id,
      cyclium_expectation_id: episode.expectation_id
    )

    deadline_ref =
      Process.send_after(self(), :budget_wall_exceeded, episode.budget["max_wall_ms"] || 120_000)

    # Include trigger_type/ref so subscribers can identify their own
    # episodes (e.g. a CLI session comparing a session_id in the trigger
    # payload) without needing a DB round-trip.
    Cyclium.Bus.broadcast("episode.started", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      expectation_id: episode.expectation_id,
      trigger_type: episode.trigger_type,
      trigger_ref: episode.trigger_ref,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    # First-class lifecycle signal: fires on the node that owns the run (unlike
    # the Bus broadcast above, which every node receives), carrying episode_id so
    # consumers can correlate start → completion and time runs. A resumed run
    # (e.g. after an approval block) emits `:resumed`, not a second `:started`.
    :telemetry.execute(
      [:cyclium, :episode, if(opts[:resume], do: :resumed, else: :started)],
      %{count: 1},
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        expectation_id: episode.expectation_id,
        conversation_id: episode.conversation_id,
        trigger_type: episode.trigger_type
      }
    )

    try do
      do_loop(episode, strategy, state, DateTime.utc_now())
    after
      Process.cancel_timer(deadline_ref)
    end
  end

  defp do_loop(episode, strategy, state, started_at) do
    # Non-blocking check for EXIT signals or wall-time budget.
    # If matched, stop the loop immediately — do NOT fall through.
    case drain_exit_signals(episode, started_at) do
      :ok ->
        :ok

      {:error, _} = err ->
        err
    end
    |> case do
      :ok ->
        continue_loop(episode, strategy, state, started_at)

      {:error, _} = err ->
        err
    end
  end

  defp drain_exit_signals(episode, started_at) do
    receive do
      {:cyclium_claim_lost, _dedupe_key} ->
        # The heartbeat detected our lease was stolen. Abort before the next
        # step / converge so we don't deliver outputs the new owner will also
        # deliver. We do NOT mark the episode failed — the new owner drives it.
        Logger.warning(
          "Work claim lost mid-run — aborting episode before further side effects",
          cyclium_episode_id: episode.id
        )

        Process.put(:cyclium_claim_lost, true)
        {:error, :claim_lost}

      :budget_wall_exceeded ->
        fail_wall_budget(episode, started_at)

      {:cyclium_cancel, reason} ->
        # Cancel between steps so the worker itself writes :canceled (no race
        # with a late converge writing :done), then stop the loop.
        Cyclium.Episodes.cancel(episode.id, reason)
        {:error, :canceled}

      {:EXIT, _from, :normal} ->
        # Normal exits (e.g. ports closing after System.cmd or HTTP requests)
        # are harmless — just drain them and continue.
        :ok

      {:EXIT, from, reason} ->
        Logger.warning(
          "Episode task received EXIT from #{inspect(from)} (#{inspect(reason)}), terminating episode",
          cyclium_episode_id: episode.id
        )

        detail = %{exit_reason: inspect(reason), exit_from: inspect(from)}

        journal_step!(episode, :episode_failed, %{
          error_class: "process_terminated",
          error_detail: detail
        })

        Cyclium.Episodes.update_status(episode.id, :failed,
          error_class: "process_terminated",
          error_detail: detail
        )

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          error_class: "process_terminated",
          error_detail: detail,
          workflow_instance_id: episode.workflow_instance_id,
          workflow_step_id: episode.workflow_step_id
        })

        {:error, :process_terminated}
    after
      0 -> :ok
    end
  end

  # Mark the episode failed for wall-time budget exhaustion. Shared by the
  # between-steps timer (:budget_wall_exceeded) and the per-step hard timeout.
  defp fail_wall_budget(episode, started_at) do
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

    error_detail = %{
      kind: "wall_time",
      used_ms: elapsed,
      max_ms: (episode.budget || %{})["max_wall_ms"]
    }

    journal_step!(episode, :episode_failed, %{
      error_class: "budget_exceeded",
      error_detail: error_detail
    })

    Cyclium.Episodes.update_status(episode.id, :failed, error_class: "budget_exceeded")

    Cyclium.Bus.broadcast("episode.failed", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: :failed,
      error_class: "budget_exceeded",
      error_detail: error_detail,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    {:error, :budget_exceeded}
  end

  # Offer the strategy a graceful convergence when the turn/token budget is
  # exhausted. Returns the converge result (a normal continue_loop return) when
  # the strategy opts in via handle_budget_exhausted/2, or `:fail` otherwise.
  defp maybe_graceful_budget_converge(episode, strategy, state) do
    if function_exported?(strategy, :handle_budget_exhausted, 2) do
      episode_ctx = build_episode_ctx(episode)

      case strategy.handle_budget_exhausted(state, episode_ctx) do
        {:converge, new_state} ->
          journal_step!(episode, :observation, %{
            result_ref: %{"budget_exhausted" => true, "graceful_converge" => true}
          })

          run_converge(episode, strategy, new_state)

        :fail ->
          :fail
      end
    else
      :fail
    end
  end

  # Hard-fail the episode for turn/token budget exhaustion.
  defp fail_turn_budget(episode, err) do
    current = Cyclium.Episodes.get!(episode.id)

    error_detail = %{
      turns_used: current.turns_used,
      max_turns: (current.budget || %{})["max_turns"],
      tokens_used: current.tokens_used,
      max_tokens: (current.budget || %{})["max_tokens"]
    }

    journal_step!(episode, :episode_failed, %{
      error_class: "budget_exceeded",
      error_detail: error_detail
    })

    Cyclium.Episodes.update_status(episode.id, :failed, error_class: "budget_exceeded")

    Cyclium.Bus.broadcast("episode.failed", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: :failed,
      error_class: "budget_exceeded",
      error_detail: error_detail,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    err
  end

  # Milliseconds left before the episode's wall-clock budget is exhausted.
  defp wall_remaining(episode, started_at) do
    max_wall = (episode.budget || %{})["max_wall_ms"] || 120_000
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
    max(max_wall - elapsed, 0)
  end

  # Run a (potentially blocking) external call under a hard wall-time deadline.
  # The between-steps timer can't interrupt an in-flight step — a tool/synth call
  # that blocks forever would blow past max_wall_ms — so the call runs in a Task
  # bounded by the remaining budget. `Task.async` propagates `$callers`, so Ecto
  # sandbox ownership and the like still work inside the task.
  #
  #   * `{:completed, value}` — finished in time (value is the call's return)
  #   * `:timed_out`          — exceeded the deadline; the task was killed
  #
  # A crash inside the call is re-raised here so it reaches EpisodeTask's rescue
  # exactly as before (preserving "crash" error_class).
  defp run_bounded(fun, remaining_ms) do
    metadata = Logger.metadata()

    task =
      Task.async(fn ->
        Logger.metadata(metadata)
        fun.()
      end)

    case Task.yield(task, remaining_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} ->
        {:completed, value}

      nil ->
        :timed_out

      {:exit, {exception, stacktrace}} when is_exception(exception) ->
        reraise(exception, stacktrace)

      {:exit, reason} ->
        exit(reason)
    end
  end

  defp continue_loop(episode, strategy, state, started_at) do
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
            episode_id: episode.id,
            actor_id: episode.actor_id,
            conversation_id: episode.conversation_id
          })

          tool_name = "#{capability}.#{action}"
          tool_started = System.monotonic_time(:millisecond)

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
              bounded =
                run_bounded(
                  fn -> Cyclium.ToolExec.call(capability, action, args, %{episode: episode}) end,
                  wall_remaining(episode, started_at)
                )

              case bounded do
                :timed_out ->
                  fail_wall_budget(episode, started_at)

                {:completed, {:ok, result, cost, redacted}} ->
                  step =
                    journal_step!(episode, :tool_call, %{
                      tool_name: tool_name,
                      args_redacted: redacted.args_redacted,
                      result_ref: redacted.result_redacted,
                      cost_tokens: cost,
                      cost_ms: System.monotonic_time(:millisecond) - tool_started
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

                {:completed, {:error, reason} = err} ->
                  step =
                    journal_step!(episode, :tool_call, %{
                      tool_name: tool_name,
                      args_redacted: drop_internal_keys(args),
                      error_class: "tool_error",
                      error_detail: %{reason: format_error_reason(reason)},
                      cost_ms: System.monotonic_time(:millisecond) - tool_started
                    })

                  handle_strategy_result(episode, strategy, state, step, err, started_at)
              end
          end

        {:synthesize, prompt_ctx} ->
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
                  synth_started = System.monotonic_time(:millisecond)

                  bounded =
                    run_bounded(
                      fn -> synthesizer.synthesize(prompt_for_synth, episode_ctx) end,
                      wall_remaining(episode, started_at)
                    )

                  case bounded do
                    :timed_out ->
                      fail_wall_budget(episode, started_at)

                    {:completed, {:ok, result}} ->
                      token_cost =
                        extract_api_token_cost(result) ||
                          fallback_estimate_tokens(synthesizer, prompt_for_synth)

                      emit_synthesis(episode, result, synth_started)

                      step =
                        journal_step!(episode, :synthesis, %{
                          args_redacted: prompt_for_storage,
                          result_ref: result,
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

                    {:completed, {:error, error_class, detail}} ->
                      emit_synthesis_error(episode, error_class, synth_started)

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

          # Symmetric with :observe — hand the checkpoint to handle_result so the
          # strategy can advance its phase. (Continuing with the *same* state
          # would re-invoke next_step unchanged and loop.) Strategies that don't
          # need to react can ignore it in their catch-all handle_result clause.
          case strategy.handle_result(state, %EpisodeStep{kind: :checkpoint}, {:ok, phase_name}) do
            {:ok, new_state} -> do_loop(episode, strategy, new_state, started_at)
            {:abort, reason} -> abort_episode(episode, reason)
          end

        {:output, type, payload} ->
          journal_step!(episode, :output_proposed, %{
            tool_name: to_string(type),
            args_redacted: payload
          })

          do_loop(episode, strategy, state, started_at)

        {:approval, request} ->
          # Checkpoint at the block so resume re-enters here without replaying
          # earlier (side-effecting) steps. Strategies that implement
          # resume_from_block/2 rebuild from the journal instead, so skip it.
          unless function_exported?(strategy, :resume_from_block, 2) do
            save_checkpoint(episode, "__blocked__", state)
          end

          journal_step!(episode, :approval_requested, %{args_redacted: request})
          Cyclium.Episodes.update_status(episode.id, :blocked)
          emit_blocked(episode, :approval)
          {:blocked, state}

        {:wait, external_ref} ->
          # See :approval above — checkpoint at the block so resume doesn't
          # replay the steps leading up to it.
          save_checkpoint(episode, "__blocked__", state)
          journal_step!(episode, :wait_started, %{result_ref: external_ref})
          Cyclium.Episodes.update_status(episode.id, :blocked)
          emit_blocked(episode, :wait)
          {:blocked, state}
      end
    else
      {:error, :budget_exceeded} = err ->
        # Give the strategy a chance to converge gracefully (e.g. emit a
        # "ran out of budget for this turn" summary) instead of hard-failing.
        case maybe_graceful_budget_converge(episode, strategy, state) do
          :fail -> fail_turn_budget(episode, err)
          converged -> converged
        end

      {:error, :loop_detected} = err ->
        fingerprints =
          Process.get(:cyclium_step_history, []) |> Enum.map(&elem(&1, 0))

        error_detail = %{
          step_fingerprints: fingerprints,
          message: "Repeating step cycle with no budget progress — strategy may be stuck"
        }

        journal_step!(episode, :episode_failed, %{
          error_class: "loop_detected",
          error_detail: error_detail
        })

        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "loop_detected")

        Cyclium.Bus.broadcast("episode.failed", %{
          episode_id: episode.id,
          actor_id: episode.actor_id,
          status: :failed,
          error_class: "loop_detected",
          error_detail: error_detail,
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

    # Re-assert claim ownership before any side effects. If the lease was stolen
    # while this episode ran (e.g. a long GC pause past the lease, then a steal),
    # the new owner is now responsible — skip findings/outputs so we don't
    # double-deliver. This also renews the lease, extending our hold across the
    # converge writes. (Dry runs have no external effects, so they're exempt.)
    if not dry_run? and lost_claim?(episode) do
      Logger.warning(
        "Lost work claim before post-converge — skipping findings/outputs to avoid double execution",
        cyclium_episode_id: episode.id
      )

      Process.put(:cyclium_claim_lost, true)
      {:error, :claim_lost}
    else
      do_post_converge(episode, converge_result, dry_run?)
    end
  end

  # True only when work claims are configured, the episode has a dedupe_key, and
  # we no longer hold the claim at the fence we acquired. `gate_owns?` returns
  # true (we own) when claims are unconfigured or the key is nil. With a fence it
  # uses the fence-aware `owns?/3` (catching steal-and-reacquire); without one it
  # falls back to an owner-only `renew/3` check.
  defp lost_claim?(episode) do
    not Cyclium.WorkClaims.gate_owns?(
      episode.dedupe_key,
      Cyclium.NodeIdentity.name(),
      Process.get(:cyclium_claim_fence)
    )
  end

  defp do_post_converge(episode, converge_result, dry_run?) do
    findings = converge_result.findings || []

    # Step 1+2+3: Persist findings (journaled in dry run; optionally persisted with prefix)
    findings_failed =
      if dry_run? do
        journal_dry_run_findings(episode, findings)
        maybe_persist_dry_run_findings(episode, findings)
        0
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

    # Step 5: Compute final episode status from delivery + finding-persist outcomes
    final_status = compute_episode_status(output_results, findings_failed)

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
        outputs_duped: count_outcomes(output_results, :duplicate),
        findings_failed: findings_failed
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

    base_payload = %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: final_status,
      summary: converge_result.summary,
      classification: converge_result.classification,
      confidence: converge_result.confidence,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    }

    payload =
      if final_status == :failed do
        Map.merge(base_payload, %{
          error_class: "all_outputs_failed",
          error_detail: %{
            outputs_failed: count_outcomes(output_results, :error),
            outputs_delivered: count_outcomes(output_results, :ok)
          }
        })
      else
        base_payload
      end

    Cyclium.Bus.broadcast(bus_event, payload)

    :telemetry.execute(
      [:cyclium, :episode, if(final_status == :failed, do: :failed, else: :completed)],
      %{count: 1, duration_ms: episode_duration_ms(episode)},
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        expectation_id: episode.expectation_id,
        conversation_id: episode.conversation_id,
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
    # Reload for the post-increment tokens_used (the struct is stale here).
    episode = Cyclium.Episodes.get!(episode.id)

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

  # Returns the count of findings that failed to persist, so the caller can
  # reflect it in the episode status and journal (a finding is often the actual
  # product of a monitoring episode — a silent persist failure must not report
  # the episode as cleanly :done).
  defp persist_findings(episode, findings) do
    Enum.reduce(findings, 0, fn action, failed ->
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
          failed

        :ok ->
          # Idempotent clear — nothing to broadcast
          failed

        {:error, reason} ->
          Logger.warning("Failed to persist finding: #{inspect(reason)}",
            finding_action: inspect(action)
          )

          failed + 1
      end
    end)
  end

  defp compute_episode_status(output_results, findings_failed) do
    successes =
      Enum.count(output_results, &match?({:ok, _}, &1)) +
        Enum.count(output_results, &match?({:duplicate, _}, &1))

    failures = Enum.count(output_results, &match?({:error, _}, &1))
    total = length(output_results)

    output_status =
      cond do
        total == 0 -> :done
        failures == 0 -> :done
        successes == 0 -> :failed
        true -> :partially_failed
      end

    # A finding that failed to persist degrades an otherwise-clean episode to
    # :partially_failed — the work didn't fully land, so don't report :done.
    if findings_failed > 0 and output_status == :done do
      :partially_failed
    else
      output_status
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
    # Extract a specific error_class from structured abort reasons so
    # downstream workflow retry policies can filter by it. Strategies
    # can use:
    #   {:abort, :synthesis_error}
    #   {:abort, {:synthesis_error, :api_error, detail}}
    #   {:abort, {error_class, detail}}
    {error_class, error_detail} = classify_abort_reason(reason)

    journal_step!(episode, :episode_failed, %{
      error_class: error_class,
      error_detail: error_detail
    })

    Cyclium.Episodes.update_status(episode.id, :failed,
      error_class: error_class,
      error_detail: error_detail
    )

    Cyclium.Bus.broadcast("episode.failed", %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      status: :failed,
      error_class: error_class,
      error_detail: error_detail,
      workflow_instance_id: episode.workflow_instance_id,
      workflow_step_id: episode.workflow_step_id
    })

    {:error, reason}
  end

  # Render a tool error reason as a compact string for UI display.
  # Today ToolExec always classifies the reason into an atom before it
  # gets here. If that contract broadens in the future (e.g. tuples or
  # strings), update this function too.
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason) when is_atom(reason), do: to_string(reason)

  # Strip framework-injected internal args (keys prefixed with "_") so
  # PIDs and other non-JSON values don't end up in the journal.
  defp drop_internal_keys(args) when is_map(args) do
    args
    |> Enum.reject(fn
      {k, _v} when is_binary(k) -> String.starts_with?(k, "_")
      {k, _v} when is_atom(k) -> k |> Atom.to_string() |> String.starts_with?("_")
      _ -> false
    end)
    |> Map.new()
  end

  defp drop_internal_keys(args), do: args

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

  # Extract {error_class_string, error_detail_map} from an abort reason.
  # Supports bare atoms, {kind, detail} tuples, and {kind, subkind, detail}
  # nested forms like {:synthesis_error, :api_error, "timeout"}.
  defp classify_abort_reason(reason) do
    case reason do
      atom when is_atom(atom) and atom != nil ->
        {to_string(atom), %{reason: inspect(reason)}}

      {kind, subkind, detail} when is_atom(kind) and is_atom(subkind) ->
        {"#{kind}:#{subkind}", %{reason: inspect(reason), detail: inspect(detail)}}

      {kind, detail} when is_atom(kind) ->
        {to_string(kind), %{reason: inspect(reason), detail: inspect(detail)}}

      _ ->
        {"abort", %{reason: inspect(reason)}}
    end
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

    if loop_detection_enabled?(episode) and repeating_cycle?(history) do
      Logger.error(
        "Loop detected: repeating step cycle with no budget progress in episode",
        cyclium_episode_id: episode.id
      )

      {:error, :loop_detected}
    else
      :ok
    end
  end

  # Per-expectation off switch (`loop_detection: false`). Registered in
  # persistent_term at actor boot; defaults to on when not registered.
  defp loop_detection_enabled?(episode) do
    with {:ok, actor} <- Cyclium.AtomGuard.existing_atom(episode.actor_id),
         {:ok, exp} <- Cyclium.AtomGuard.existing_atom(episode.expectation_id) do
      :persistent_term.get({:cyclium_expectation_loop_detection, actor, exp}, true)
    else
      _ -> true
    end
  end

  defp repeating_cycle?(history) when length(history) < 3, do: false

  defp repeating_cycle?(history) do
    # A repeating action cycle is only treated as a stuck loop if the episode
    # made NO budget progress (no tokens consumed) across the window. A strategy
    # that legitimately repeats an action while consuming tokens (e.g. an LLM
    # retry/refine loop) is making progress and is bounded by the token budget;
    # killing it here would be a false positive. Token-free repetition (e.g. a
    # pure polling loop) can still be turned off per-expectation with
    # `loop_detection: false`.
    cyclic?(Enum.map(history, &elem(&1, 0))) and no_token_progress?(history)
  end

  defp cyclic?(fingerprints) do
    max_cycle = div(length(fingerprints), 2)

    Enum.any?(1..max_cycle, fn cycle_len ->
      cycle = Enum.take(fingerprints, cycle_len)
      repetitions = div(length(fingerprints), cycle_len)

      repetitions >= 2 and
        Enum.chunk_every(Enum.take(fingerprints, cycle_len * repetitions), cycle_len)
        |> Enum.all?(&(&1 == cycle))
    end)
  end

  defp no_token_progress?(history) do
    tokens = Enum.map(history, &elem(&1, 1))
    Enum.max(tokens) == Enum.min(tokens)
  end

  # Track by content hash (same kind with different data is fine — only
  # identical actions indicate a cycle) alongside a token-spend snapshot, so the
  # loop check can tell "stuck" from "repeating-but-making-progress".
  defp record_step_kind(step_action) do
    entry = {:erlang.phash2(step_action), Process.get(:cyclium_loop_tokens, 0)}

    history = Process.get(:cyclium_step_history, [])
    Process.put(:cyclium_step_history, [entry | Enum.take(history, @max_history - 1)])
  end

  defp increment_turn(%Episode{} = episode) do
    import Ecto.Query

    from(e in Episode, where: e.id == ^episode.id)
    |> repo().update_all(inc: [turns_used: 1])
  end

  # Extract actual input + output token counts from the API response.
  # Returns nil if no usage data is present (e.g. non-API synthesizer).
  # Episode parked on an approval/external wait. `reason` is :approval | :wait.
  defp emit_blocked(%Episode{} = episode, reason) do
    :telemetry.execute([:cyclium, :episode, :blocked], %{count: 1}, %{
      episode_id: episode.id,
      actor_id: episode.actor_id,
      expectation_id: episode.expectation_id,
      conversation_id: episode.conversation_id,
      reason: reason
    })
  end

  # Wall time from the episode's recorded start to now, for the completion event.
  defp episode_duration_ms(%Episode{started_at: %DateTime{} = started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
  end

  defp episode_duration_ms(_), do: nil

  # Emit a synthesis (LLM call) event carrying the data needed to build an
  # `llm` span for LLM observability: duration, input/output/total token usage,
  # the model, and the ids to correlate (episode + conversation/session).
  defp emit_synthesis(%Episode{} = episode, result, started_ms) do
    usage = result[:usage] || result["usage"] || %{}
    input = usage[:input_tokens] || usage["input_tokens"] || 0
    output = usage[:output_tokens] || usage["output_tokens"] || 0

    :telemetry.execute(
      [:cyclium, :step, :synthesis],
      %{
        count: 1,
        duration_ms: System.monotonic_time(:millisecond) - started_ms,
        input_tokens: input,
        output_tokens: output,
        total_tokens: input + output
      },
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        conversation_id: episode.conversation_id,
        model: result[:model] || result["model"]
      }
    )
  end

  defp emit_synthesis_error(%Episode{} = episode, error_class, started_ms) do
    :telemetry.execute(
      [:cyclium, :step, :synthesis],
      %{count: 1, duration_ms: System.monotonic_time(:millisecond) - started_ms},
      %{
        episode_id: episode.id,
        actor_id: episode.actor_id,
        conversation_id: episode.conversation_id,
        error_class: to_string(error_class)
      }
    )
  end

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

    # Running per-process token total, snapshotted by record_step_kind so loop
    # detection can distinguish a stuck cycle from one that's consuming budget.
    Process.put(:cyclium_loop_tokens, Process.get(:cyclium_loop_tokens, 0) + token_cost)

    from(e in Episode, where: e.id == ^episode.id)
    |> repo().update_all(inc: [tokens_used: token_cost])
  end

  # Best-effort: a checkpoint exists only to make resume cheaper/safer, so it
  # must never take down the episode. If the state can't be persisted (e.g. it
  # carries a value the JSON column can't encode), log loudly and continue —
  # resume will fall back to a fresh init from the trigger.
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

    :ok
  rescue
    e ->
      Logger.error(
        "[Cyclium.EpisodeRunner] Failed to checkpoint episode #{episode.id} at phase " <>
          "#{inspect(phase_name)}: #{Exception.message(e)}. Continuing without a checkpoint — " <>
          "resume will re-init from the trigger."
      )

      :ok
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
      kind: kind,
      tool_name: attrs[:tool_name],
      error_class: attrs[:error_class],
      cost_tokens: attrs[:cost_tokens]
    })

    inserted
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

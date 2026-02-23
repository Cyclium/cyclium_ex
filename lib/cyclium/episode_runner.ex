defmodule Cyclium.EpisodeRunner do
  @moduledoc """
  Executes the episode loop: calls strategy callbacks, enforces budgets,
  journals steps, and runs the post-converge sequence.

  The post-converge pipeline (Phase 3) persists findings, delivers outputs
  via `Cyclium.Output.Router`, and computes final episode status from
  delivery outcomes.
  """

  require Logger

  alias Cyclium.Schemas.{Episode, EpisodeStep}

  defp repo, do: Cyclium.repo()

  def execute_loop(%Episode{} = episode, strategy, state) do
    deadline_ref = Process.send_after(self(), :budget_wall_exceeded, episode.budget["max_wall_ms"] || 120_000)

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
          error_detail: %{kind: "wall_time", used_ms: elapsed, max_ms: episode.budget["max_wall_ms"]}
        })
        Cyclium.Episodes.update_status(episode.id, :failed, error_class: "budget_exceeded")
        {:error, :budget_exceeded}
    after
      0 -> :ok
    end

    with :ok <- check_budget(episode) do
      episode_ctx = build_episode_ctx(episode)

      case strategy.next_step(state, episode_ctx) do
        :done ->
          journal_step!(episode, :episode_completed, %{})
          Cyclium.Episodes.update_status(episode.id, :done)
          {:ok, state}

        :converge ->
          run_converge(episode, strategy, state)

        {:tool_call, capability, action, args} ->
          :telemetry.execute([:cyclium, :step, :tool_call], %{count: 1},
            %{tool: capability, action: action, episode_id: episode.id})

          step = journal_step!(episode, :tool_call, %{
            tool_name: "#{capability}.#{action}",
            args_redacted: args
          })

          case Cyclium.ToolExec.call(capability, action, args, %{episode: episode}) do
            {:ok, result, cost} ->
              increment_budget(episode, cost)
              handle_strategy_result(episode, strategy, state, step, {:ok, result}, started_at)

            {:error, _reason} = err ->
              handle_strategy_result(episode, strategy, state, step, err, started_at)
          end

        {:synthesize, prompt_ctx} ->
          :telemetry.execute([:cyclium, :step, :synthesis], %{count: 1},
            %{episode_id: episode.id})

          step = journal_step!(episode, :synthesis, %{args_redacted: prompt_ctx})
          handle_strategy_result(episode, strategy, state, step, {:ok, %{pending: true}}, started_at)

        {:observe, data} ->
          :telemetry.execute([:cyclium, :step, :observation], %{count: 1},
            %{actor_id: episode.actor_id, episode_id: episode.id})

          journal_step!(episode, :observation, %{result_ref: data})
          case strategy.handle_result(state, %EpisodeStep{kind: :observation}, {:ok, data}) do
            {:ok, new_state} -> do_loop(episode, strategy, new_state, started_at)
            {:abort, reason} -> abort_episode(episode, reason)
          end

        {:checkpoint, phase_name} ->
          save_checkpoint(episode, phase_name, state)
          do_loop(episode, strategy, state, started_at)

        {:output, type, payload} ->
          journal_step!(episode, :output_proposed, %{tool_name: to_string(type), args_redacted: payload})
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
      {:error, :budget_exceeded} = err -> err
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
    # Step 1+2+3: Persist findings, publish Bus events, journal steps
    persist_findings(episode, converge_result.findings || [])

    # Step 4: Deliver outputs via OutputRouter
    output_results =
      (converge_result.outputs || [])
      |> Enum.map(fn proposal ->
        Cyclium.Output.Router.route(proposal, episode, build_episode_ctx(episode))
      end)

    # Step 5: Compute final episode status from delivery outcomes
    final_status = compute_episode_status(output_results)

    # Step 6: Journal and set episode status
    step_kind = if final_status in [:done, :partially_failed], do: :episode_completed, else: :episode_failed

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

    # Step 7: Bus event + telemetry
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

    if final_status == :failed do
      {:error, :all_outputs_failed}
    else
      {:ok, converge_result}
    end
  end

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
          Logger.warning("[Cyclium] Failed to persist finding #{inspect(action)}: #{inspect(reason)}")
      end
    end)
  end

  defp compute_episode_status(output_results) do
    successes = Enum.count(output_results, &match?({:ok, _}, &1)) +
                Enum.count(output_results, &match?({:duplicate, _}, &1))
    failures = Enum.count(output_results, &match?({:error, _}, &1))
    total = length(output_results)

    cond do
      total == 0     -> :done
      failures == 0  -> :done
      successes == 0 -> :failed
      true           -> :partially_failed
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
    kind = case action do
      {:raise, _}     -> :finding_raised
      {:update, _, _} -> :finding_updated
      {:clear, _}     -> :finding_cleared
      {:clear, _, _}  -> :finding_cleared
    end

    journal_step!(episode, kind, %{
      result_ref: %{finding_id: finding.id, finding_key: finding.finding_key}
    })
  end

  defp abort_episode(episode, reason) do
    journal_step!(episode, :episode_failed, %{error_class: "abort", error_detail: %{reason: inspect(reason)}})
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
      episode.turns_used >= max_turns -> {:error, :budget_exceeded}
      episode.tokens_used >= max_tokens -> {:error, :budget_exceeded}
      true -> :ok
    end
  end

  defp increment_budget(%Episode{} = episode, token_cost) when is_integer(token_cost) do
    import Ecto.Query

    from(e in Episode, where: e.id == ^episode.id)
    |> repo().update_all(inc: [turns_used: 1, tokens_used: token_cost])
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
    from(c in Cyclium.Schemas.EpisodeCheckpoint, where: c.episode_id == ^episode_id, select: count())
    |> repo().one()
  end

  defp journal_step!(%Episode{} = episode, kind, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    step_no = next_step_no(episode.id)

    step = %EpisodeStep{
      episode_id: episode.id,
      step_no: step_no,
      kind: kind,
      tool_name: attrs[:tool_name],
      args_hash: attrs[:args_hash],
      args_redacted: attrs[:args_redacted],
      result_ref: attrs[:result_ref],
      error_class: attrs[:error_class],
      error_detail: attrs[:error_detail],
      side_effect_key: attrs[:side_effect_key],
      cost_tokens: attrs[:cost_tokens],
      cost_ms: attrs[:cost_ms],
      created_at: now
    }

    repo().insert!(step)
  end

  defp next_step_no(episode_id) do
    import Ecto.Query

    (from(s in EpisodeStep, where: s.episode_id == ^episode_id, select: max(s.step_no))
     |> repo().one()) || 0
    |> Kernel.+(1)
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
end

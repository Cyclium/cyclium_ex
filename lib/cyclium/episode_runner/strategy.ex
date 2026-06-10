defmodule Cyclium.EpisodeRunner.Strategy do
  @moduledoc """
  Behaviour for episode strategies. A strategy defines the investigation logic
  for a specific expectation — how to gather data, classify, and produce outputs.
  """

  @callback init(episode :: %Cyclium.Schemas.Episode{}, trigger :: Cyclium.Trigger.t()) ::
              {:ok, state :: map()}

  @callback next_step(state :: map(), episode_ctx :: map()) ::
              {:tool_call, atom(), atom(), map()}
              | {:synthesize, map()}
              | {:observe, map()}
              | {:output, atom(), map()}
              | {:checkpoint, binary()}
              | {:approval, map()}
              | {:wait, map()}
              | :converge
              | :done

  @callback handle_result(
              state :: map(),
              step :: %Cyclium.Schemas.EpisodeStep{},
              result :: term()
            ) ::
              {:ok, new_state :: map()}
              | {:retry, new_state :: map()}
              | {:abort, reason :: term()}

  @callback converge(state :: map(), episode_ctx :: map()) ::
              {:ok, Cyclium.ConvergeResult.t()}
              | {:partial, Cyclium.ConvergeResult.t(), failures :: [term()]}

  @callback workflow_result(state :: map(), converge_result :: Cyclium.ConvergeResult.t()) ::
              map()

  @doc """
  Optional hook invoked when the turn/token budget is exhausted between steps.

  Lets a strategy convert a hard budget failure into a graceful convergence —
  e.g. an interactive actor can emit a "ran out of budget for this turn" summary
  instead of leaving the episode `:failed` with no user-facing message.

  Return `{:converge, new_state}` to run the normal converge path with the given
  state, or `:fail` to keep the default behaviour (episode fails with
  `error_class: "budget_exceeded"`). Strategies that don't implement this
  callback always fail. This is *not* called for wall-time exhaustion
  (`max_wall_ms`), which can fire mid-step and is always a hard failure.
  """
  @callback handle_budget_exhausted(state :: map(), episode_ctx :: map()) ::
              {:converge, new_state :: map()} | :fail

  @optional_callbacks [workflow_result: 2, handle_budget_exhausted: 2]
end

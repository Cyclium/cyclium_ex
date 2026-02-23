defmodule Cyclium.EpisodeRunner.Strategy do
  @moduledoc """
  Behaviour for episode strategies. A strategy defines the investigation logic
  for a specific expectation — how to gather data, classify, and produce outputs.
  """

  alias Cyclium.Schemas.{Episode, EpisodeStep}

  @callback init(episode :: Episode.t(), trigger :: Cyclium.Trigger.t()) ::
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

  @callback handle_result(state :: map(), step :: EpisodeStep.t(), result :: term()) ::
              {:ok, new_state :: map()}
              | {:retry, new_state :: map()}
              | {:abort, reason :: term()}

  @callback converge(state :: map(), episode_ctx :: map()) ::
              {:ok, Cyclium.ConvergeResult.t()}
              | {:partial, Cyclium.ConvergeResult.t(), failures :: [term()]}

  @callback workflow_result(state :: map(), converge_result :: Cyclium.ConvergeResult.t()) ::
              map()

  @optional_callbacks [workflow_result: 2]
end

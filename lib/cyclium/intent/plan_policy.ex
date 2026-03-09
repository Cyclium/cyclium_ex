defmodule Cyclium.Intent.PlanPolicy do
  @moduledoc """
  Behaviour for app-owned plan policy. The consuming app implements this
  to control what interactive actors are allowed to do.
  """

  alias Cyclium.Intent.{ActionPlan, ToolSignature}
  alias Cyclium.OutputProposal

  @callback validate_plan(ctx :: map(), plan :: ActionPlan.t(), strategy_cfg :: map()) ::
              :ok | {:deny, reason :: binary()}

  @callback validate_tool_args(
              ctx :: map(),
              tool :: binary(),
              args :: map(),
              signature :: ToolSignature.t()
            ) ::
              :ok | {:deny, reason :: binary()}

  @callback validate_output(ctx :: map(), output :: OutputProposal.t()) ::
              :ok | {:deny, reason :: binary()}
end

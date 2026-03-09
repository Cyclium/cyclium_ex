defmodule Cyclium.Intent.ActionPlan do
  @moduledoc """
  A structured output the synthesizer returns when interpreting user intent.
  Describes what the interactive actor should do next.
  """

  @plan_kinds [
    :tool_call,
    :multi_tool_plan,
    :output_proposal,
    :explain_only,
    :request_approval,
    :workflow_trigger
  ]

  @risk_levels [:low, :medium, :high]

  @derive Jason.Encoder

  @enforce_keys [:kind, :risk, :why]
  defstruct [
    :kind,
    :risk,
    :why,
    steps: [],
    tool: nil,
    output: nil,
    explanation: nil,
    workflow: nil,
    approval: nil,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          kind: plan_kind(),
          risk: risk_level(),
          why: binary(),
          steps: [Cyclium.Intent.ToolCallStep.t()],
          tool: Cyclium.Intent.ToolCallStep.t() | nil,
          output: Cyclium.OutputProposal.t() | nil,
          explanation: binary() | nil,
          workflow: Cyclium.Intent.WorkflowTrigger.t() | nil,
          approval: map() | nil,
          meta: map()
        }

  @type plan_kind ::
          :tool_call
          | :multi_tool_plan
          | :output_proposal
          | :explain_only
          | :request_approval
          | :workflow_trigger

  @type risk_level :: :low | :medium | :high

  def plan_kinds, do: @plan_kinds
  def risk_levels, do: @risk_levels
end

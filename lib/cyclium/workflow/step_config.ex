defmodule Cyclium.Workflow.StepConfig do
  @moduledoc """
  Configuration for a single workflow step, accumulated by the Workflow DSL.
  """

  @type t :: %__MODULE__{
          id: atom(),
          actor: module() | binary(),
          expectation: atom(),
          type: :episode | :interactive_conversation,
          input_fn: (map(), map() -> map()) | nil,
          input_map: map() | nil,
          depends_on: [atom()],
          requires_approval: boolean(),
          goal: map() | nil,
          audience_target: map() | nil,
          on_outcome: map() | nil
        }

  defstruct [
    :id,
    :actor,
    :expectation,
    type: :episode,
    input_fn: nil,
    input_map: nil,
    depends_on: [],
    requires_approval: false,
    goal: nil,
    audience_target: nil,
    on_outcome: nil
  ]
end

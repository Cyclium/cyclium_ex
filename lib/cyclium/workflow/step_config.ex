defmodule Cyclium.Workflow.StepConfig do
  @moduledoc """
  Configuration for a single workflow step, accumulated by the Workflow DSL.
  """

  @type t :: %__MODULE__{
          id: atom(),
          actor: module(),
          expectation: atom(),
          input_fn: (map(), map() -> map()) | nil,
          depends_on: [atom()],
          requires_approval: boolean()
        }

  defstruct [:id, :actor, :expectation, input_fn: nil, depends_on: [], requires_approval: false]
end

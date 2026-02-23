defmodule Cyclium.OutputProposal do
  @moduledoc """
  A proposed output from a strategy's converge phase.
  The strategy must set the dedupe_key — it requires domain knowledge.
  """

  @type t :: %__MODULE__{
          type: atom(),
          dedupe_key: binary(),
          payload: map(),
          requires_approval: boolean()
        }

  defstruct [:type, :dedupe_key, :payload, requires_approval: false]
end

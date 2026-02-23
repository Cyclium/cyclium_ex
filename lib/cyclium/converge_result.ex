defmodule Cyclium.ConvergeResult do
  @moduledoc """
  Returned by Strategy.converge/2. Contains outputs, findings, summary,
  classification, and confidence for post-converge processing.
  """

  @type finding_action ::
          {:raise, map()}
          | {:update, binary(), map()}
          | {:clear, binary()}
          | {:clear, binary(), binary()}

  @type t :: %__MODULE__{
          outputs: [Cyclium.OutputProposal.t()],
          findings: [finding_action()],
          summary: binary(),
          classification: map() | nil,
          confidence: float() | nil
        }

  defstruct outputs: [],
            findings: [],
            summary: "",
            classification: nil,
            confidence: nil
end

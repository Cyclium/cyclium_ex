defmodule Cyclium.Intent.WorkflowTrigger do
  @moduledoc """
  Sub-struct for action plans that start workflows.
  """

  @derive Jason.Encoder

  @enforce_keys [:workflow_id]
  defstruct [
    :workflow_id,
    input: %{},
    purpose: nil
  ]

  @type t :: %__MODULE__{
          workflow_id: binary(),
          input: map(),
          purpose: binary() | nil
        }
end

defmodule Cyclium.Intent.ToolCallStep do
  @moduledoc """
  A single tool invocation within an action plan.
  """

  @derive Jason.Encoder

  @enforce_keys [:tool, :action, :args]
  defstruct [:tool, :action, :args]

  @type t :: %__MODULE__{
          tool: binary(),
          action: binary(),
          args: map()
        }
end

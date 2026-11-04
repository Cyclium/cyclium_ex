defmodule Cyclium.Intent.ToolCallStep do
  @moduledoc """
  A single tool invocation within an action plan.
  """

  @derive Jason.Encoder

  @enforce_keys [:tool, :action, :args]
  defstruct [:tool, :action, :args, :id]

  @typedoc """
  `id` is the provider's id for the call (a native `tool_use` id), when it
  gave one. A multi-turn transcript pairs the call's result with it.
  """
  @type t :: %__MODULE__{
          tool: binary(),
          action: binary(),
          args: map(),
          id: binary() | nil
        }
end

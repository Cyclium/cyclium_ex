defmodule Cyclium.Intent.ToolSignature do
  @moduledoc """
  Declared in strategy config by the consuming app.
  The runtime matches plan tool calls against these.
  """

  @enforce_keys [:name, :version, :side_effect]
  defstruct [
    :name,
    :version,
    :side_effect,
    :args_schema,
    constraints: %{}
  ]

  @type t :: %__MODULE__{
          name: binary(),
          version: pos_integer(),
          side_effect: :read | :write | :external_effect,
          args_schema: binary() | nil,
          constraints: map()
        }
end

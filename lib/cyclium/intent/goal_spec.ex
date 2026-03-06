defmodule Cyclium.Intent.GoalSpec do
  @moduledoc """
  Defines what a conversation is trying to accomplish and how we know it's done.
  Set at conversation creation time by a workflow step, the consuming app, or implicitly.
  """

  @derive Jason.Encoder

  @enforce_keys [:type]
  defstruct [
    :type,
    description: nil,
    terminal_outcomes: %{},
    completion_criteria: %{},
    constraints: %{},
    context: %{}
  ]

  @type t :: %__MODULE__{
          type: binary(),
          description: binary() | nil,
          terminal_outcomes: map(),
          completion_criteria: map(),
          constraints: map(),
          context: map()
        }
end

defmodule Cyclium.Intent.Origin do
  @moduledoc """
  Describes how and why a conversation was created.
  """

  @enforce_keys [:type]
  defstruct [
    :type,
    principal: nil,
    workflow_ref: nil,
    trigger_ref: nil,
    actor_id: nil
  ]

  @type t :: %__MODULE__{
          type: :user | :workflow | :system,
          principal: map() | nil,
          workflow_ref: map() | nil,
          trigger_ref: map() | nil,
          actor_id: atom() | binary() | nil
        }
end

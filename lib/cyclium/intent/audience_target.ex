defmodule Cyclium.Intent.AudienceTarget do
  @moduledoc """
  For non-user-initiated conversations: who is this conversation for?
  """

  @enforce_keys [:mode]
  defstruct [
    :mode,
    principal_id: nil,
    pool: nil,
    delivery: :await
  ]

  @type t :: %__MODULE__{
          mode: :principal | :pool | :any,
          principal_id: binary() | nil,
          pool: binary() | nil,
          delivery: :await | :notify | :both
        }
end

defmodule Cyclium.Trigger do
  @moduledoc """
  Typed trigger ref structs — one per trigger_type.
  Strategies pattern-match on trigger type in `init/2`.
  """

  defmodule Schedule do
    @type t :: %__MODULE__{scheduled_at: DateTime.t()}
    defstruct [:scheduled_at]
  end

  defmodule Event do
    @type t :: %__MODULE__{
            event_id: binary(),
            event_type: binary(),
            entity_id: binary() | nil,
            payload: map()
          }
    defstruct [:event_id, :event_type, :entity_id, :payload]
  end

  defmodule Manual do
    @type t :: %__MODULE__{requested_by: binary(), reason: binary()}
    defstruct [:requested_by, :reason]
  end

  defmodule Workflow do
    @type t :: %__MODULE__{
            workflow_instance_id: binary(),
            workflow_step_id: binary(),
            input: map()
          }
    defstruct [:workflow_instance_id, :workflow_step_id, :input]
  end

  defmodule Interactive do
    @type t :: %__MODULE__{
            conversation_id: binary(),
            message: binary(),
            principal: map() | nil,
            history: [map()]
          }
    defstruct [:conversation_id, :message, principal: nil, history: []]
  end

  @type t :: Schedule.t() | Event.t() | Manual.t() | Workflow.t() | Interactive.t()
end

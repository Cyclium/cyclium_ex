defmodule Cyclium.Expectation do
  @moduledoc """
  A declarative "contract with reality." The smallest unit of responsibility.

  Expectations are defined in code via the Actor DSL, not stored in the database.
  They declare what should be true and how to investigate when things drift.
  """

  @type t :: %__MODULE__{
          id: atom(),
          actor_id: atom(),
          domain: atom(),
          trigger: tuple(),
          subscribes_to: [binary()],
          filter: map(),
          debounce_ms: non_neg_integer() | nil,
          cooldown_ms: non_neg_integer() | nil,
          subject_key: atom() | nil,
          resources: [map()],
          outputs: [atom()],
          budget: map(),
          log_strategy: atom(),
          audit_level: atom(),
          retention_days: non_neg_integer() | nil,
          description: binary(),
          synthesizer: module() | nil,
          recovery_policy: :fail | :restart
        }

  defstruct [
    :id,
    :actor_id,
    :domain,
    :trigger,
    :synthesizer,
    subscribes_to: [],
    filter: %{},
    debounce_ms: nil,
    cooldown_ms: nil,
    subject_key: nil,
    resources: [],
    outputs: [],
    budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000},
    log_strategy: :timeline,
    audit_level: :standard,
    retention_days: 90,
    description: "",
    recovery_policy: :fail
  ]
end

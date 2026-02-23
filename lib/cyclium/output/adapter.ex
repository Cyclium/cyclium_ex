defmodule Cyclium.Output.Adapter do
  @moduledoc """
  Behaviour for output delivery adapters (email, Slack, issues, etc.).
  The consuming app provides implementations per output type.
  """

  @callback deliver(type :: atom(), payload :: map(), ctx :: map()) ::
              {:ok, ref :: map()} | {:error, reason :: term()}
end

defmodule Cyclium.Tool do
  @moduledoc """
  Behaviour for tool implementations.
  Tools are provided by the consuming app and wrapped by ToolExec.
  """

  @callback call(action :: atom(), args :: map(), ctx :: map()) ::
              {:ok, result :: term()} | {:error, reason :: term()}

  @callback redact(args :: map()) :: map()

  @callback side_effect?() :: boolean()

  @callback cache_ttl() :: non_neg_integer() | :no_cache

  @callback cache_scope(args :: map()) :: binary()
end

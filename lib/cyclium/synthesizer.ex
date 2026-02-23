defmodule Cyclium.Synthesizer do
  @moduledoc """
  Behaviour for LLM synthesis integration.
  The consuming app provides the implementation.
  """

  @callback synthesize(prompt_ctx :: map(), episode_ctx :: map()) ::
              {:ok, result :: map()}
              | {:error, error_class :: atom(), detail :: term()}

  @callback estimate_tokens(prompt_ctx :: map()) :: non_neg_integer()
end

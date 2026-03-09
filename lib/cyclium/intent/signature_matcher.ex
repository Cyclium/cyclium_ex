defmodule Cyclium.Intent.SignatureMatcher do
  @moduledoc """
  Matches a tool call from an action plan against allowed tool signatures.
  """

  alias Cyclium.Intent.{ToolCallStep, ToolSignature}

  @spec match(ToolCallStep.t(), [ToolSignature.t()]) ::
          {:ok, ToolSignature.t()} | {:error, :no_matching_signature}
  def match(%ToolCallStep{tool: tool_name}, signatures) do
    case Enum.find(signatures, &(&1.name == tool_name)) do
      nil -> {:error, :no_matching_signature}
      sig -> {:ok, sig}
    end
  end

  @spec has_side_effects?([ToolCallStep.t()], [ToolSignature.t()]) :: boolean()
  def has_side_effects?(steps, signatures) do
    Enum.any?(steps, fn step ->
      case match(step, signatures) do
        {:ok, %{side_effect: effect}} when effect in [:write, :external_effect] -> true
        _ -> false
      end
    end)
  end
end

defmodule Cyclium.Intent.SignatureMatcher do
  @moduledoc """
  Matches a tool call from an action plan against allowed tool signatures.

  A step matches only when a signature with the same tool `name` exists **and**
  that signature allows the step's `action` (see
  `Cyclium.Intent.ToolSignature.allows_action?/2`). Matching the name alone would
  let a plan reach any `call/3` clause the tool module happens to implement,
  including ones withheld from this actor on purpose.
  """

  alias Cyclium.Intent.{ToolCallStep, ToolSignature}

  @spec match(ToolCallStep.t(), [ToolSignature.t()]) ::
          {:ok, ToolSignature.t()}
          | {:error, :no_matching_signature | :action_not_allowed}
  def match(%ToolCallStep{tool: tool_name, action: action}, signatures) do
    case Enum.find(signatures, &(&1.name == tool_name)) do
      nil ->
        {:error, :no_matching_signature}

      sig ->
        if ToolSignature.allows_action?(sig, action),
          do: {:ok, sig},
          else: {:error, :action_not_allowed}
    end
  end

  @doc """
  Whether any step calls a `write` / `external_effect` action. Uses the
  action's own side-effect class when the signature declares one, otherwise the
  tool's class. A step that does not match any signature is not counted; the
  gate denies it before preview is considered.
  """
  @spec has_side_effects?([ToolCallStep.t()], [ToolSignature.t()]) :: boolean()
  def has_side_effects?(steps, signatures) do
    Enum.any?(steps, fn step ->
      case match(step, signatures) do
        {:ok, sig} ->
          ToolSignature.side_effect_for(sig, step.action) in [:write, :external_effect]

        _ ->
          false
      end
    end)
  end
end

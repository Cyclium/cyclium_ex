defmodule Cyclium.DynamicWorkflow.InputResolver do
  @moduledoc """
  Resolves declarative input_map paths against trigger and prior step data.

  Used by dynamic workflows to compute step inputs without Elixir functions.

  ## Path syntax

  - `"trigger.order_id"` — resolves `trigger_ref["order_id"]`
  - `"prior.validate.classification.primary"` — resolves `prior[:validate][:classification]["primary"]`
  - Any other value is treated as a static value and passed through as-is

  ## Example

      input_map = %{
        "order_id" => "trigger.order_id",
        "risk" => "prior.compliance_check.classification.primary",
        "mode" => "fast"
      }

      InputResolver.resolve(input_map, trigger_ref, prior)
      # => %{"order_id" => "abc123", "risk" => "high", "mode" => "fast"}
  """

  @doc """
  Resolve an input_map against trigger_ref and prior step results.

  Returns a map with the same keys as input_map, values resolved from paths.
  """
  def resolve(nil, _trigger_ref, _prior), do: %{}

  def resolve(input_map, trigger_ref, prior) when is_map(input_map) do
    Enum.map(input_map, fn {key, path} ->
      {key, resolve_path(path, trigger_ref, prior)}
    end)
    |> Enum.into(%{})
  end

  defp resolve_path(path, trigger_ref, prior) when is_binary(path) do
    cond do
      String.starts_with?(path, "trigger.") ->
        rest = String.slice(path, 8..-1//1)
        get_nested(trigger_ref, String.split(rest, "."))

      String.starts_with?(path, "prior.") ->
        rest = String.slice(path, 6..-1//1)
        [step_id | path_parts] = String.split(rest, ".")

        step_key =
          try do
            String.to_existing_atom(step_id)
          rescue
            ArgumentError -> String.to_atom(step_id)
          end

        step_result = Map.get(prior || %{}, step_key, %{})
        get_nested(step_result, path_parts)

      true ->
        path
    end
  end

  defp resolve_path(value, _trigger_ref, _prior), do: value

  defp get_nested(nil, _), do: nil
  defp get_nested(data, []), do: data

  defp get_nested(data, [key | rest]) when is_map(data) do
    val = Map.get(data, key) || Map.get(data, to_atom_safe(key))
    get_nested(val, rest)
  end

  defp get_nested(_, _), do: nil

  defp to_atom_safe(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end
end

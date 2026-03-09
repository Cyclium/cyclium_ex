defmodule Cyclium.Intent.GoalEvaluator.RequiredFields do
  @moduledoc """
  Built-in evaluator: checks if all required fields have been collected
  across conversation turns.
  """

  @behaviour Cyclium.Intent.GoalEvaluator

  @impl true
  def evaluate(goal, conversation_state, result) do
    fields_spec = get_fields_spec(goal)
    collected = get_collected(conversation_state, result)

    missing =
      fields_spec
      |> Enum.filter(fn field -> field_required?(field) end)
      |> Enum.reject(fn field -> field_satisfied?(field, collected) end)

    if missing == [] do
      {:resolved, "completed", collected}
    else
      :continue
    end
  end

  defp get_fields_spec(goal) do
    case goal.completion_criteria do
      %{fields: fields} when is_list(fields) -> fields
      %{"fields" => fields} when is_list(fields) -> normalize_fields(fields)
      _ -> []
    end
  end

  defp normalize_fields(fields) do
    Enum.map(fields, fn
      f when is_map(f) ->
        %{
          key: f["key"] || f[:key],
          required: f["required"] || f[:required] || false,
          type: parse_type(f["type"] || f[:type]),
          min: f["min"] || f[:min]
        }
    end)
  end

  defp parse_type("list"), do: :list
  defp parse_type("boolean"), do: :boolean
  defp parse_type(:list), do: :list
  defp parse_type(:boolean), do: :boolean
  defp parse_type(_), do: :any

  defp field_required?(%{required: true}), do: true
  defp field_required?(_), do: false

  defp field_satisfied?(field, collected) do
    key = field[:key] || field["key"]
    value = Map.get(collected, key) || Map.get(collected, to_string(key))

    cond do
      is_nil(value) -> false
      field[:type] == :list -> is_list(value) and length(value) >= (field[:min] || 1)
      field[:type] == :boolean -> is_boolean(value) and value == true
      true -> true
    end
  end

  defp get_collected(conversation_state, result) do
    prior = Map.get(conversation_state, :collected_fields, %{})

    new_fields =
      case result.classification do
        %{"collected_fields" => fields} when is_map(fields) -> fields
        %{collected_fields: fields} when is_map(fields) -> fields
        _ -> %{}
      end

    Map.merge(prior, new_fields)
  end
end

defmodule Cyclium.Intent.ConstraintChecks do
  @moduledoc """
  Evaluates generic constraints from tool signatures against tool call args.
  """

  alias Cyclium.Intent.ToolSignature

  @spec check(map(), ToolSignature.t()) :: :ok | {:deny, binary()}
  def check(_args, %ToolSignature{constraints: constraints}) when map_size(constraints) == 0 do
    :ok
  end

  def check(args, %ToolSignature{constraints: constraints}) do
    constraints
    |> Enum.reduce_while(:ok, fn {key, limit}, :ok ->
      case check_constraint(key, limit, args) do
        :ok -> {:cont, :ok}
        {:deny, _} = deny -> {:halt, deny}
      end
    end)
  end

  defp check_constraint("max_rows", max, args) do
    rows = Map.get(args, "limit") || Map.get(args, "max_rows")

    cond do
      is_nil(rows) -> :ok
      is_integer(rows) and rows <= max -> :ok
      true -> {:deny, "max_rows constraint exceeded: #{inspect(rows)} > #{max}"}
    end
  end

  defp check_constraint("max_window_minutes", max, args) do
    window = Map.get(args, "window_minutes")

    cond do
      is_nil(window) -> :ok
      is_number(window) and window <= max -> :ok
      true -> {:deny, "max_window_minutes constraint exceeded: #{window} > #{max}"}
    end
  end

  defp check_constraint("allowed_fields", allowed, args) do
    fields = Map.get(args, "fields") || []

    disallowed = Enum.reject(fields, &(&1 in allowed))

    if disallowed == [] do
      :ok
    else
      {:deny, "disallowed fields: #{inspect(disallowed)}"}
    end
  end

  defp check_constraint(_key, _limit, _args), do: :ok
end

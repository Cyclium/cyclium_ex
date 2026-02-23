defmodule Cyclium.ToolExec do
  @moduledoc """
  Wraps every tool call with: capability check, caching, redaction, journaling.

  Phase 1 skeleton — capability checking and basic execution. Full caching
  and rate limiting wired in later phases.
  """

  def call(capability, action, args, %{episode: _episode} = ctx) do
    with :ok <- check_capability(ctx, capability, action) do
      execute(capability, action, args, ctx)
    end
  end

  defp check_capability(_ctx, _capability, _action) do
    # Phase 1: capability enforcement is advisory only.
    # Full enforcement wired when Actor GenServer is built (Phase 2).
    :ok
  end

  defp execute(capability, action, args, _ctx) do
    registry = Application.get_env(:cyclium, :capability_registry)

    if registry do
      tool_module = registry.tool_for(capability)

      case tool_module.call(action, args, %{}) do
        {:ok, result} ->
          {:ok, result, 0}

        {:error, reason} ->
          {:error, classify_error(reason)}
      end
    else
      {:error, :no_capability_registry}
    end
  end

  defp classify_error(:timeout), do: :tool_timeout
  defp classify_error(:unavailable), do: :tool_unavailable
  defp classify_error(:auth_failed), do: :tool_auth_failed
  defp classify_error(:rate_limited), do: :tool_rate_limited
  defp classify_error(:not_found), do: :tool_not_found
  defp classify_error(_), do: :tool_invalid_response
end

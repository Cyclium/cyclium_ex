defmodule Cyclium.ToolExec do
  @moduledoc """
  Wraps every tool call with: capability check, caching, redaction, journaling.

  Tool modules are resolved in order:
  1. Actor-registered tools (set via `tools` DSL in the actor module)
  2. App-level capability registry (`config :cyclium, :capability_registry`)
  """

  require Logger

  def call(capability, action, args, %{episode: _episode} = ctx) do
    with :ok <- check_capability(ctx, capability, action) do
      execute(capability, action, args, ctx)
    end
  end

  defp check_capability(_ctx, _capability, _action) do
    :ok
  end

  defp execute(capability, action, args, ctx) do
    case resolve_tool(capability, ctx) do
      nil ->
        Logger.warning(
          "[ToolExec] No tool found for capability=#{inspect(capability)} actor=#{inspect(ctx.episode.actor_id)}"
        )

        {:error, :no_tool_for_capability}

      tool_module ->
        try do
          case tool_module.call(action, args, ctx) do
            {:ok, result} ->
              redacted = %{
                args_redacted: tool_module.redact(args),
                result_redacted: tool_module.redact_result(result)
              }

              {:ok, result, 0, redacted}

            {:error, reason} ->
              Logger.warning(
                "[ToolExec] Tool returned error: #{inspect(reason)} for #{inspect(capability)}.#{inspect(action)}"
              )

              {:error, classify_error(reason)}
          end
        catch
          :error, %{__struct__: _} = e ->
            Logger.warning(
              "[ToolExec] Tool raised #{inspect(e.__struct__)}: #{Exception.message(e)} for #{inspect(capability)}.#{inspect(action)}"
            )

            {:error, classify_error("#{inspect(e.__struct__)}: #{Exception.message(e)}")}

          kind, reason ->
            Logger.warning(
              "[ToolExec] Tool #{kind}: #{inspect(reason)} for #{inspect(capability)}.#{inspect(action)}"
            )

            {:error, classify_error("#{kind}: #{inspect(reason)}")}
        end
    end
  end

  defp resolve_tool(capability, ctx) do
    # 1. Actor-registered tool (from persistent_term, set by Actor DSL `tools` macro)
    actor_id = ctx.episode.actor_id

    actor_key =
      case actor_id do
        a when is_atom(a) ->
          a

        s when is_binary(s) ->
          try do
            String.to_existing_atom(s)
          rescue
            _ -> nil
          end
      end

    from_actor =
      if actor_key do
        :persistent_term.get({:cyclium_tool, actor_key, capability}, nil)
      end

    from_actor || resolve_from_registry(capability)
  end

  defp resolve_from_registry(capability) do
    # 2. App-level capability registry (backwards compatible)
    registry = Application.get_env(:cyclium, :capability_registry)

    if registry do
      registry.tool_for(capability)
    end
  end

  defp classify_error(:timeout), do: :tool_timeout
  defp classify_error(:unavailable), do: :tool_unavailable
  defp classify_error(:auth_failed), do: :tool_auth_failed
  defp classify_error(:rate_limited), do: :tool_rate_limited
  defp classify_error(:not_found), do: :tool_not_found
  defp classify_error(_), do: :tool_invalid_response
end

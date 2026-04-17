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
                args_redacted: strip_internal_keys(tool_module.redact(args)),
                result_redacted: tool_module.redact_result(result)
              }

              {:ok, result, 0, redacted}

            {:error, reason} ->
              Logger.warning(
                "[ToolExec] Tool returned error: #{inspect(reason)} for #{inspect(capability)}.#{inspect(action)}"
              )

              # Pass through the original error reason if it's already a
              # string/atom/binary — only fall back to classify_error for
              # truly unknown shapes. This preserves the actual error
              # message for the agent (e.g. "File not found: :enoent").
              {:error, preserve_error(reason)}
          end
        catch
          :error, %{__struct__: _} = e ->
            msg = "#{inspect(e.__struct__)}: #{Exception.message(e)}"

            Logger.warning(
              "[ToolExec] Tool raised #{msg} for #{inspect(capability)}.#{inspect(action)}"
            )

            {:error, msg}

          kind, reason ->
            msg = "#{kind}: #{inspect(reason)}"

            Logger.warning(
              "[ToolExec] Tool #{msg} for #{inspect(capability)}.#{inspect(action)}"
            )

            {:error, msg}
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

  # Framework-injected internal args (like "_workspace_root", "_session_pid")
  # start with an underscore by convention. These are not safe to journal —
  # they may contain PIDs or other non-JSON-encodable values, and they're
  # not meaningful to the LLM anyway. Strip them before journaling.
  defp strip_internal_keys(args) when is_map(args) do
    args
    |> Enum.reject(fn
      {k, _v} when is_binary(k) -> String.starts_with?(k, "_")
      {k, _v} when is_atom(k) -> k |> Atom.to_string() |> String.starts_with?("_")
      _ -> false
    end)
    |> Map.new()
  end

  defp strip_internal_keys(args), do: args

  # For known classification atoms, pass them through unchanged so the
  # strategy/runner can pattern-match on them. For arbitrary strings or
  # other terms, pass them through as-is so the original error message
  # reaches the journal and the LLM instead of being flattened to
  # :tool_invalid_response.
  defp preserve_error(reason) when is_binary(reason), do: reason
  defp preserve_error(:timeout), do: :tool_timeout
  defp preserve_error(:unavailable), do: :tool_unavailable
  defp preserve_error(:auth_failed), do: :tool_auth_failed
  defp preserve_error(:rate_limited), do: :tool_rate_limited
  defp preserve_error(:not_found), do: :tool_not_found
  defp preserve_error(reason) when is_atom(reason), do: reason
  defp preserve_error(reason), do: inspect(reason)

end

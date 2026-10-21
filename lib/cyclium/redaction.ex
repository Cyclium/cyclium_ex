defmodule Cyclium.Redaction do
  @moduledoc """
  Key-based redaction applied to tool arguments, tool results and output
  payloads before they are journaled.

  Tools may implement `redact/1` and `redact_result/1` themselves; this is the
  floor beneath them, so a credential that rides in a map under an obvious key
  never reaches `cyclium_episode_steps` or `cyclium_outputs` even when a tool
  keeps the identity defaults.

  The key pattern is configurable:

      config :cyclium, :redact_key_pattern, ~r/^(.*_)?(secret|password)s?$/i

  Matching is on the key alone; values are never inspected. Structs are left
  untouched (they are not journaled as-is anyway).
  """

  # A bare `token` only matches the whole key: `input_tokens` / `output_tokens`
  # are usage counts, not secrets.
  @default_pattern ~r/^(?:(?:.*[_-])?(?:secret|password|passwd|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|bearer|authorization|credential|private[_-]?key|client[_-]?secret)s?|tokens?)$/i

  @placeholder "[REDACTED]"

  @doc "The placeholder written in place of a redacted value."
  @spec placeholder() :: binary()
  def placeholder, do: @placeholder

  @doc "Redact every value under a sensitive key, recursively through maps and lists."
  @spec redact_sensitive(term()) :: term()
  def redact_sensitive(term), do: walk(term, pattern())

  @doc "Whether `key` names a sensitive value under the configured pattern."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key), do: sensitive?(key, pattern())

  defp walk(%{__struct__: _} = struct, _pattern), do: struct

  defp walk(map, pattern) when is_map(map) do
    Map.new(map, fn {k, v} ->
      if sensitive?(k, pattern), do: {k, @placeholder}, else: {k, walk(v, pattern)}
    end)
  end

  defp walk(list, pattern) when is_list(list), do: Enum.map(list, &walk(&1, pattern))
  defp walk(other, _pattern), do: other

  defp sensitive?(key, pattern) when is_binary(key), do: Regex.match?(pattern, key)

  defp sensitive?(key, pattern) when is_atom(key) and not is_nil(key),
    do: sensitive?(Atom.to_string(key), pattern)

  defp sensitive?(_key, _pattern), do: false

  defp pattern do
    case Application.get_env(:cyclium, :redact_key_pattern) do
      %Regex{} = re -> re
      _ -> @default_pattern
    end
  end
end

defmodule Cyclium.DryRun.FindingPrefixer do
  @moduledoc """
  Rewrites finding actions with prefixed keys for dry run persistence.

  When `dry_run_opts["persist_findings"]` is set, findings are persisted to the DB
  with prefixed `finding_key` and `actor_id` values so they don't collide with live findings.

  ## Prefix resolution

    - `true` → default prefix `"dry_run"`
    - `"custom"` → uses `"custom"` as the prefix

  ## Example

      # finding_key "po_stalled:PO-123" becomes "dry_run:po_stalled:PO-123"
      FindingPrefixer.prefix_actions([{:raise, %{finding_key: "po_stalled:PO-123"}}], "dry_run")
  """

  @default_prefix "dry_run"

  @doc """
  Returns the persist prefix from an episode's dry_run_opts, or nil if
  dry run finding persistence is disabled.
  """
  def persist_prefix(%{dry_run_opts: opts}) when is_map(opts) do
    case Map.get(opts, "persist_findings") do
      true -> @default_prefix
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> nil
    end
  end

  def persist_prefix(_), do: nil

  @doc """
  Rewrites finding actions with prefixed keys.
  """
  def prefix_actions(findings, prefix) do
    Enum.map(findings, &prefix_action(&1, prefix))
  end

  defp prefix_action({:raise, params}, prefix) do
    params =
      params
      |> Map.update!(:finding_key, &"#{prefix}:#{&1}")
      |> Map.update(:actor_id, nil, fn
        nil -> nil
        id -> "#{prefix}:#{id}"
      end)

    {:raise, params}
  end

  defp prefix_action({:update, key, changes}, prefix) do
    {:update, "#{prefix}:#{key}", changes}
  end

  defp prefix_action({:clear, key}, prefix) do
    {:clear, "#{prefix}:#{key}"}
  end

  defp prefix_action({:clear, key, reason}, prefix) do
    {:clear, "#{prefix}:#{key}", reason}
  end
end

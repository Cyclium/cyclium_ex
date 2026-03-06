defmodule Cyclium.NodeIdentity do
  @moduledoc """
  Resolves the identity of the current node for work claiming and trigger requests.

  By default uses `node()`, but this can be overridden via config for environments
  where multiple instances share the same Erlang node name (e.g., dev containers
  all running with identical node names).

  ## Configuration

      # Use a static override
      config :cyclium, :node_identity, "dev-jane"

      # Use a callback module
      config :cyclium, :node_identity, {MyApp.NodeIdentity, :resolve, []}

  If unconfigured, falls back to `node() |> to_string()` with a random suffix
  appended when `node()` returns `:nonode@nohost` (non-distributed mode).
  """

  @doc """
  Returns a unique string identifier for this node instance.
  """
  @spec name() :: String.t()
  def name do
    case Application.get_env(:cyclium, :node_identity) do
      nil ->
        default_name()

      {mod, fun, args} when is_atom(mod) and is_atom(fun) ->
        apply(mod, fun, args) |> to_string()

      static when is_binary(static) ->
        static

      other ->
        to_string(other)
    end
  end

  defp default_name do
    case node() do
      :nonode@nohost ->
        # Non-distributed mode — generate a stable identity for this OS process
        persistent_identity()

      name ->
        to_string(name)
    end
  end

  # Returns a stable identity for the lifetime of this BEAM instance.
  # Stored in persistent_term so it survives process crashes but not restarts.
  defp persistent_identity do
    case :persistent_term.get(:cyclium_node_identity, nil) do
      nil ->
        suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
        identity = "nonode-#{System.pid()}-#{suffix}"
        :persistent_term.put(:cyclium_node_identity, identity)
        identity

      identity ->
        identity
    end
  end
end

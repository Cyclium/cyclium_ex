defmodule Cyclium.Env do
  @moduledoc """
  Optional per-node **dedup identity** for sharing one database across otherwise
  independent nodes that run the same actors.

  This is orthogonal to `Cyclium.StackSlug`:

    * **stack slug** selects *which actors run* (host-app placement) and scopes
      recovery — different stacks already run differently-named actors, so their
      dedup keys differ via `actor_id`.
    * **env** distinguishes *otherwise-identical nodes* for dedup/claim purposes,
      so two `:full` nodes running the same actor against the same DB (e.g. a
      developer's laptop and a hosted test deployment) each create and run their
      **own** episodes instead of one deduping the other out.

  When `env` is set, it's folded into framework-generated dedup keys (episode
  dedupe_key — which the work-claim lease and derived output keys inherit — and
  explicit output keys). When unset, keys are **byte-identical** to single-env
  behavior. Findings are intentionally *not* env-scoped: their rows are shared
  and cross-visible across envs, which is the desired behavior here.

  ## Configuration

      # Set per node (e.g. from a CYCLIUM_ENV env var in runtime.exs). Leave
      # unset on the shared/hosted node; set it on the isolated (dev) node.
      config :cyclium, :env, "dev-jane"
  """

  @doc """
  Returns the configured env as a string, or `nil` if unset/blank.
  """
  @spec current() :: String.t() | nil
  def current do
    case Application.get_env(:cyclium, :env) do
      nil -> nil
      "" -> nil
      env -> to_string(env)
    end
  end

  @doc """
  Folds the current env into a dedup key as a suffix when set; returns the key
  unchanged when unset (byte-identical to single-env behavior). `nil` stays `nil`.

  ## Examples

      # env "dev-jane" set
      iex> Cyclium.Env.scope_key("event:resource_monitor:check:123")
      "event:resource_monitor:check:123:dev-jane"

      # no env set
      iex> Cyclium.Env.scope_key("event:resource_monitor:check:123")
      "event:resource_monitor:check:123"
  """
  @spec scope_key(String.t()) :: String.t()
  @spec scope_key(nil) :: nil
  def scope_key(nil), do: nil

  def scope_key(key) when is_binary(key) do
    case current() do
      nil -> key
      env -> "#{key}:#{env}"
    end
  end
end

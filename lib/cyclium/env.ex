defmodule Cyclium.Env do
  @moduledoc """
  Optional per-node **dedup identity** for sharing one database across otherwise
  independent nodes that run the same actors.

  This is orthogonal to `Cyclium.StackSlug`:

    * **stack slug** selects *which actors run* (host-app placement) and scopes
      recovery — different stacks already run differently-named actors, so their
      dedup keys differ via `actor_id`.
    * **env** distinguishes *otherwise-identical nodes* so two `:full` nodes
      running the same actors against the same DB (e.g. a developer's laptop and
      a hosted test deployment, or an RC node sharing prod's DB) operate as
      **independent worlds**: each creates and runs its own episodes, recovers
      only its own orphans, and keeps its own findings.

  When `env` is set it scopes work along three dimensions; when unset, behavior
  is **byte-identical** to single-env operation (legacy `NULL` rows belong to the
  unset/default env):

    1. **Dedup/claim keys** — folded into the episode `dedupe_key` (which the
       work-claim lease and derived output keys inherit) and explicit output
       keys via `scope_key/1`.
    2. **Recovery** — episodes and workflow instances carry `source_env`
       (mirroring `source_stack`); `Cyclium.Recovery` only sweeps/reconciles its
       own env, matched by **strict equality** so an env-tagged node never
       resurrects the default node's work.
    3. **Findings** — each env keeps its own active finding per key (the
       `cyclium_findings.env` column + a `[finding_key, status, env]` unique
       index); `Cyclium.Findings` reads and upserts are cordoned to the current
       env.

  An RC node configured as `:full` with recovery on, tagged `env: "rc"` and
  sharing prod's DB, can therefore drive UI interactions and run actors fully
  independently of the prod node (`env` unset) without either deduping,
  recovering, or clearing the other's work.

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

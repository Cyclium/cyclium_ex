defmodule Cyclium.OutputProposal do
  @moduledoc """
  A proposed output from a strategy's converge phase.

  ## Deduplication

  Outputs are deduplicated by a unique `dedupe_key` on `cyclium_outputs`, which
  guards against double-delivery — but only if the key is **stable across
  re-runs** of the same work (recovery restart, a stolen-lease re-run, etc.). A
  key built from anything run-local (a timestamp, `make_ref`, a random id) lets
  two runs produce different keys and deliver twice.

  Two ways to supply it:

    * `:key` — a stable, domain-meaningful logical key (e.g. `"limit_alert"`).
      The framework derives the actual dedupe_key from the **episode's**
      dedupe_key/id + output type + this key, so it's automatically stable across
      re-runs of the same episode. **Prefer this** — it's re-run-safe by
      construction and needs no per-strategy care.

    * `:dedupe_key` — an explicit, fully-controlled key. Use this for
      cross-episode/temporal dedup (e.g. "one alert per 4-hour window" via
      `Cyclium.Window.bucket/2`), where you deliberately want a key that is *not*
      tied to a single episode. You are responsible for its stability.

  If both are given, `:dedupe_key` wins. If neither is given, the output is not
  deduplicated.
  """

  @type t :: %__MODULE__{
          type: atom(),
          dedupe_key: binary() | nil,
          key: binary() | nil,
          payload: map(),
          requires_approval: boolean()
        }

  defstruct [:type, :dedupe_key, :key, :payload, requires_approval: false]
end

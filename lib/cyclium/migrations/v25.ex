defmodule Cyclium.Migrations.V25 do
  @moduledoc """
  V25: Add an open `metadata` bag (`:map` → nvarchar(max) via TDS) to
  `cyclium_episodes` and `cyclium_episode_steps`.

  Every existing `:map` column on these tables has a specific, framework-owned
  purpose (`trigger_ref`, `budget`, `classification`, `error_detail`,
  `dry_run_opts`, `args_redacted`, `result_ref`), so there was no place to hang
  per-run attributes — most importantly *which model/LLM actually ran*. The
  model is actor-level config resolved at runtime and observable in Datadog
  (`llm_model`), but it was not queryable in the DB.

  `metadata` is a general key/value bag so new per-run attributes don't each need
  a migration:

    * On `cyclium_episodes` it holds the **primary** model the episode ran under
      (e.g. `%{"model" => "gpt-5.4-2026-03-05"}`), stamped once.
    * On `cyclium_episode_steps` it records a model **only when that step
      diverges** from the episode's primary model, so a single-model episode
      doesn't repeat the model on every synthesis step.

  Nullable with no default, matching the other `:map` columns (a SQL default of
  `%{}` isn't portable to the nvarchar(max) representation); the app layer
  treats `NULL` as the empty bag.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_episodes) do
      add(:metadata, :map)
    end

    alter table(:cyclium_episode_steps) do
      add(:metadata, :map)
    end
  end

  def down do
    alter table(:cyclium_episode_steps) do
      remove(:metadata)
    end

    alter table(:cyclium_episodes) do
      remove(:metadata)
    end
  end
end

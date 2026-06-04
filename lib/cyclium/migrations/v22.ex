defmodule Cyclium.Migrations.V22 do
  @moduledoc """
  V22: Add an `env` dimension for cordoning work across nodes that share a DB
  *and* a stack slug.

  Complements `Cyclium.Env` (which already folds env into dedup/claim/output
  keys) by giving the framework durable columns to scope on:

    * `source_env` on `cyclium_episodes` / `cyclium_workflow_instances` — mirrors
      `source_stack` (V18) so recovery sweeps and workflow reconciliation only
      pick up orphans created by the **same env**. Unlike `source_stack` (where
      `NULL` means "match any stack"), `source_env` is matched by strict
      equality: a `NULL` row belongs to the unset/default env, so an env-tagged
      node won't recover the default node's work and vice-versa. Legacy rows are
      `NULL` and therefore owned by the unset-env (default) node.

    * `env` on `cyclium_findings` — scopes finding upserts/reads so each env keeps
      its own active finding per key. The unique index is widened to include
      `env` so two envs can each hold an active finding with the same
      `finding_key`.

    * `source_env` on `cyclium_trigger_requests` — mirrors `source_stack` (V14)
      so the `TriggerRequests.Poller` on a full-mode node only claims deferred
      requests from its own env. Each env's trigger-only nodes feed that env's
      full nodes.

  This makes a config like "RC node = `:full` with recovery on, sharing prod's DB
  but tagged `env: "rc"`" operate fully independently of the prod node.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_episodes) do
      add(:source_env, :string)
    end

    alter table(:cyclium_workflow_instances) do
      add(:source_env, :string)
    end

    alter table(:cyclium_findings) do
      add(:env, :string)
    end

    alter table(:cyclium_trigger_requests) do
      add(:source_env, :string)
    end

    create(index(:cyclium_episodes, [:source_env, :status]))
    create(index(:cyclium_workflow_instances, [:source_env, :status]))
    create(index(:cyclium_trigger_requests, [:status, :source_env, :inserted_at]))

    # Widen the partial unique index (V13) to include env so each env keeps its
    # own active finding per key.
    drop(
      index(:cyclium_findings, [:finding_key, :status],
        name: :cyclium_findings_finding_key_status_index
      )
    )

    create(
      unique_index(:cyclium_findings, [:finding_key, :status, :env],
        where: "status != 'superseded'",
        name: :cyclium_findings_finding_key_status_env_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:cyclium_findings, [:finding_key, :status, :env],
        name: :cyclium_findings_finding_key_status_env_index
      )
    )

    create(
      unique_index(:cyclium_findings, [:finding_key, :status],
        where: "status != 'superseded'",
        name: :cyclium_findings_finding_key_status_index
      )
    )

    drop_if_exists(index(:cyclium_trigger_requests, [:status, :source_env, :inserted_at]))
    drop_if_exists(index(:cyclium_workflow_instances, [:source_env, :status]))
    drop_if_exists(index(:cyclium_episodes, [:source_env, :status]))

    alter table(:cyclium_trigger_requests) do
      remove(:source_env)
    end

    alter table(:cyclium_findings) do
      remove(:env)
    end

    alter table(:cyclium_workflow_instances) do
      remove(:source_env)
    end

    alter table(:cyclium_episodes) do
      remove(:source_env)
    end
  end
end

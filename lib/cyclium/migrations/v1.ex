defmodule Cyclium.Migrations.V1 do
  @moduledoc """
  V1: Core Phase 1 tables — episodes, steps, checkpoints, findings, outputs.

  SQL Server 2017 compatible — uses :map (nvarchar(max) via TDS adapter),
  standard indexes only (no partial/filtered indexes), no JSON operators in DDL.
  """

  use Ecto.Migration

  def up do
    create table(:cyclium_episodes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:actor_id, :string, null: false)
      add(:expectation_id, :string, null: false)
      add(:spec_rev, :string)
      add(:trigger_type, :string, null: false)
      add(:trigger_ref, :map)
      add(:dedupe_key, :string)
      add(:status, :string, null: false, default: "running")
      add(:phase, :string)
      add(:budget, :map)
      add(:turns_used, :integer, default: 0)
      add(:tokens_used, :integer, default: 0)
      add(:attempts, :integer, default: 0)
      add(:max_attempts, :integer, default: 3)
      add(:classification, :map)
      add(:confidence, :float)
      add(:summary, :text)
      add(:log_strategy, :string)
      add(:error_class, :string)
      add(:error_detail, :map)
      add(:workflow_instance_id, :binary_id)
      add(:workflow_step_id, :string)
      add(:started_at, :utc_datetime, null: false)
      add(:finished_at, :utc_datetime)
      add(:queued_at, :utc_datetime)
    end

    create(index(:cyclium_episodes, [:actor_id, :expectation_id]))
    create(index(:cyclium_episodes, [:status]))
    create(index(:cyclium_episodes, [:dedupe_key]))
    create(index(:cyclium_episodes, [:workflow_instance_id]))

    create table(:cyclium_episode_steps, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:step_no, :integer, null: false)
      add(:kind, :string, null: false)
      add(:tool_name, :string)
      add(:args_hash, :string)
      add(:args_redacted, :map)
      add(:result_ref, :map)
      add(:error_class, :string)
      add(:error_detail, :map)
      add(:side_effect_key, :string)
      add(:cost_tokens, :integer)
      add(:cost_ms, :integer)
      add(:created_at, :utc_datetime, null: false)
    end

    create(index(:cyclium_episode_steps, [:episode_id, :step_no]))

    create table(:cyclium_episode_checkpoints, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:checkpoint_no, :integer, null: false)
      add(:phase, :string, null: false)
      add(:schema_version, :integer, null: false)
      add(:state, :map, null: false)
      add(:created_at, :utc_datetime, null: false)
    end

    create(index(:cyclium_episode_checkpoints, [:episode_id, :checkpoint_no]))

    create table(:cyclium_findings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:actor_id, :string, null: false)
      add(:finding_key, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:class, :string, null: false)
      add(:severity, :string)
      add(:confidence, :float)
      add(:subject, :map)
      add(:evidence_refs, :map)
      add(:summary, :text)
      add(:raised_by_episode_id, references(:cyclium_episodes, type: :binary_id), null: false)
      add(:cleared_by_episode_id, references(:cyclium_episodes, type: :binary_id))
      add(:raised_at, :utc_datetime, null: false)
      add(:cleared_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
      # Denormalized subject fields for indexable queries on SQL Server
      # (JSON_VALUE not indexable in SQL Server 2017)
      add(:subject_kind, :string)
      add(:subject_id, :string)
    end

    create(index(:cyclium_findings, [:actor_id, :status, :class]))
    create(index(:cyclium_findings, [:status, :class]))
    create(index(:cyclium_findings, [:subject_kind, :subject_id, :status]))
    # Standard unique index on finding_key + status combo.
    # Uniqueness of active finding_keys enforced at the application layer
    # (upsert with on_conflict) since filtered indexes vary across backends.
    create(unique_index(:cyclium_findings, [:finding_key, :status]))

    create table(:cyclium_outputs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:type, :string, null: false)
      add(:dedupe_key, :string, null: false)
      add(:status, :string, null: false, default: "proposed")
      add(:payload_redacted, :map)
      add(:delivered_ref, :map)
      add(:error_class, :string)
      add(:error_detail, :map)
      add(:created_at, :utc_datetime, null: false)
      add(:delivered_at, :utc_datetime)
    end

    create(unique_index(:cyclium_outputs, [:dedupe_key]))
    create(index(:cyclium_outputs, [:episode_id]))
  end

  def down do
    drop(table(:cyclium_outputs))
    drop(table(:cyclium_findings))
    drop(table(:cyclium_episode_checkpoints))
    drop(table(:cyclium_episode_steps))
    drop(table(:cyclium_episodes))
  end
end

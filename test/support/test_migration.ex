defmodule Cyclium.Test.Migration do
  @moduledoc """
  Single flat migration for the test database. Creates all cyclium tables in
  their final post-V11 form. Avoids replaying incremental alter/modify steps
  that SQLite handles poorly.
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
      add(:workflow_step_no, :integer)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      add(:queued_at, :utc_datetime_usec)
      add(:archived_at, :utc_datetime)
      add(:mode, :string, default: "live")
      add(:dry_run_opts, :map)
    end

    create(index(:cyclium_episodes, [:actor_id, :expectation_id]))
    create(index(:cyclium_episodes, [:status]))
    create(index(:cyclium_episodes, [:dedupe_key]))
    create(index(:cyclium_episodes, [:workflow_instance_id]))
    create(index(:cyclium_episodes, [:archived_at]))

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

    create table(:cyclium_episode_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:episode_id, references(:cyclium_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:format, :string, default: "markdown")
      add(:content, :text)
      add(:last_step_no_rendered, :integer, default: 0)
      add(:created_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:cyclium_episode_logs, [:episode_id]))

    create table(:cyclium_findings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:actor_id, :string, null: false)
      add(:expectation_id, :string)
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
      add(:subject_kind, :string)
      add(:subject_id, :string)
      add(:archived_at, :utc_datetime)
      add(:caused_by_key, :string, size: 512)
      add(:expires_at, :utc_datetime)
    end

    create(index(:cyclium_findings, [:actor_id, :status, :class]))
    create(index(:cyclium_findings, [:status, :class]))
    create(index(:cyclium_findings, [:subject_kind, :subject_id, :status]))
    create(unique_index(:cyclium_findings, [:finding_key, :status]))
    create(index(:cyclium_findings, [:archived_at]))
    create(index(:cyclium_findings, [:caused_by_key]))
    create(index(:cyclium_findings, [:expires_at]))

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

    create table(:cyclium_work_claims, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:dedupe_key, :string, null: false)
      add(:owner_node, :string)
      add(:state, :string)
      add(:lease_until, :utc_datetime)
      add(:claimed_at, :utc_datetime)
      add(:last_heartbeat_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
      add(:attempt, :integer, default: 1)
      add(:work_type, :string, size: 128)
      add(:error_detail, :map)
    end

    create(unique_index(:cyclium_work_claims, [:dedupe_key]))
    create(index(:cyclium_work_claims, [:state, :lease_until]))

    create table(:cyclium_workflow_instances, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:workflow_id, :string, null: false)
      add(:trigger_ref, :map)
      add(:status, :string, null: false, default: "running")
      add(:step_states, :map)
      add(:started_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
      add(:mode, :string, default: "live")
      add(:dry_run_opts, :map)
      add(:created_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(index(:cyclium_workflow_instances, [:workflow_id, :status]))
    create(index(:cyclium_workflow_instances, [:status]))

    create table(:cyclium_agent_definitions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:actor_id, :string, null: false)
      add(:domain, :string)
      add(:config, :text)
      add(:expectations, :text)
      add(:strategy_ref, :string)
      add(:strategy_template, :string)
      add(:strategy_config, :text)
      add(:enabled, :boolean, default: true)
      add(:created_by, :string)
      add(:inserted_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:cyclium_agent_definitions, [:actor_id]))

    create table(:cyclium_workflow_definitions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:workflow_id, :string, null: false)
      add(:trigger_type, :string)
      add(:trigger_event, :string)
      add(:steps, :text)
      add(:failure_policies, :text)
      add(:enabled, :boolean, default: true)
      add(:created_at, :utc_datetime)
      add(:updated_at, :utc_datetime)
    end

    create(unique_index(:cyclium_workflow_definitions, [:workflow_id]))
  end

  def down do
    drop(table(:cyclium_workflow_definitions))
    drop(table(:cyclium_agent_definitions))
    drop(table(:cyclium_workflow_instances))
    drop(table(:cyclium_work_claims))
    drop(table(:cyclium_outputs))
    drop(table(:cyclium_findings))
    drop(table(:cyclium_episode_logs))
    drop(table(:cyclium_episode_checkpoints))
    drop(table(:cyclium_episode_steps))
    drop(table(:cyclium_episodes))
  end
end

defmodule Cyclium.Migrations.V19 do
  @moduledoc """
  V19: Convert legacy SQL Server `TEXT` columns to `nvarchar(max)` so emoji and
  other non-CP1252 characters round-trip correctly. No-op on Postgres/SQLite.

  Background
  ----------
  Earlier migrations declared columns with Ecto's `:text` type. On Postgres and
  SQLite this maps to UTF-8 `TEXT` and preserves any Unicode. On the Tds
  adapter, `:text` falls through the catch-all type mapping in
  `ecto_sql`'s `Ecto.Adapters.Tds.Connection` and emits the literal SQL Server
  `TEXT` type — a legacy, collation-bound, non-Unicode type (deprecated since
  SQL Server 2005). On a CP1252 collation (the default on many installs),
  characters outside the codepage — emoji, CJK, most non-Latin scripts — are
  silently replaced with `?` on write.

  This migration alters every affected column to `nvarchar(max)` on SQL Server
  only. Rows already stored as `?` remain lost; the migration unblocks future
  writes.

  Notes
  -----
  * `ALTER COLUMN text -> nvarchar(max)` converts rows in place but is not
    online — it takes a schema lock proportional to table size. Consumers with
    large `cyclium_episode_logs` tables should plan maintenance accordingly.
  * Nullability is preserved (`cyclium_workflow_definitions.steps` is
    `NOT NULL`; everything else is nullable).
  * None of the target columns are indexed today, and `nvarchar(max)` can't
    participate in a regular B-tree index anyway — same as `text` couldn't.
  """

  use Ecto.Migration

  @columns [
    {"cyclium_episodes", "summary"},
    {"cyclium_episodes", "dry_run_opts"},
    {"cyclium_episode_logs", "content"},
    {"cyclium_findings", "summary"},
    {"cyclium_agent_definitions", "config"},
    {"cyclium_agent_definitions", "expectations"},
    {"cyclium_agent_definitions", "strategy_config"},
    {"cyclium_agent_definitions", "principal"},
    {"cyclium_workflow_definitions", "steps"},
    {"cyclium_workflow_definitions", "failure_policies"},
    {"cyclium_workflow_instances", "dry_run_opts"}
  ]

  @not_null [{"cyclium_workflow_definitions", "steps"}]

  def up do
    if tds?() do
      for {table, col} <- @columns do
        execute(
          "ALTER TABLE #{table} ALTER COLUMN #{col} nvarchar(max) #{nullability(table, col)}"
        )
      end
    end

    :ok
  end

  def down do
    if tds?() do
      for {table, col} <- @columns do
        execute("ALTER TABLE #{table} ALTER COLUMN #{col} text #{nullability(table, col)}")
      end
    end

    :ok
  end

  defp tds?, do: repo().__adapter__() == Ecto.Adapters.Tds

  defp nullability(table, col) do
    if {table, col} in @not_null, do: "NOT NULL", else: "NULL"
  end
end

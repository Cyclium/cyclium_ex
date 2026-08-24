defmodule Cyclium.Migrations.V26 do
  @moduledoc """
  V26: Widen the JSON-bearing `cyclium_conversations` columns to
  nvarchar(max).

  `goal`, `origin`, `audience_target`, `result` and `collected_fields` are all
  written by `Cyclium.Conversations` as `Jason.encode!` output, but V15 created
  them as bare `:string` — nvarchar(255) under TDS. Any real payload overflows
  and SQL Server raises 8152 ("String or binary data would be truncated"),
  which surfaces as a raise from `Repo.update` rather than a changeset error.
  nvarchar(max) is what the episode tables already use for JSON of unknown size
  (`trigger_ref`, `budget`, `classification`, `metadata`, checkpoint `state`);
  this brings conversations in line.

  `modify(column, :string, size: :max)` is used rather than
  `modify(column, :map)` so the Ecto schema keeps `field(_, :string)` and
  `Cyclium.Conversations` keeps doing its own `Jason.encode!` / `Jason.decode!`.
  Only the column width changes; the read/write code and the on-disk bytes are
  untouched.

  `principal` is deliberately excluded. It also holds JSON, but a host
  application may define PERSISTED computed columns over it (extracting, say, an
  org id or user id via `JSON_VALUE`), and SQL Server refuses to alter a column
  that a computed column references. A framework migration can't know whether a
  host has done that, so widening `principal` stays out of the shared migration.
  No principal payload has overflowed in practice, so leaving it is the right
  call; if it ever needs widening it must coordinate dropping and recreating the
  host's computed columns.

  Note on `down/0`: shrinking back to nvarchar(255) fails with the same 8152 on
  any row already holding a value longer than 255 characters. Down is a
  development affordance, not a safe rollback once large payloads exist.
  """

  use Ecto.Migration

  @json_columns [:goal, :origin, :audience_target, :result, :collected_fields]

  def up do
    alter table(:cyclium_conversations) do
      for column <- @json_columns do
        modify(column, :string, size: :max, null: true)
      end
    end
  end

  def down do
    alter table(:cyclium_conversations) do
      for column <- @json_columns do
        modify(column, :string, size: 255, null: true)
      end
    end
  end
end

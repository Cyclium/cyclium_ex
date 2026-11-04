defmodule Cyclium.Migrations.V27 do
  @moduledoc """
  V27: `budget_tokens_used` on `cyclium_episodes`, the token count an episode's
  `max_tokens` budget is checked against.

  `tokens_used` stays the tokens an episode's calls actually sent and received.
  `budget_tokens_used` is the same count with cached input read back at the
  budget's `cache_read_weight` (1.0 unless set), so a prompt cache can relieve
  a budget without `tokens_used` misreporting what was sent.

  Existing rows are backfilled from `tokens_used`, so an episode running across
  the migration keeps the budget it has spent.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_episodes) do
      add(:budget_tokens_used, :integer, default: 0)
    end

    flush()

    execute("UPDATE cyclium_episodes SET budget_tokens_used = tokens_used")
  end

  def down do
    alter table(:cyclium_episodes) do
      remove(:budget_tokens_used)
    end
  end
end

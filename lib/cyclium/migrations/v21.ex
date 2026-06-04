defmodule Cyclium.Migrations.V21 do
  @moduledoc """
  V21: Add `fence` (monotonic ownership generation) to `cyclium_work_claims`.

  The fence increments on every acquire/steal/reclaim of a claim. A running
  episode holds the fence it acquired; before delivering outputs it re-checks
  that the live claim still carries that fence (via `Cyclium.WorkClaims.gate_owns?/3`).
  This catches a lease that was stolen — and possibly re-acquired by the same
  node (A → B → A) — while a stalled node was mid-run, closing the residual
  double-delivery window left open by the owner-only ownership check.

  Existing rows get fence `0`; new claims start at `1`.
  """

  use Ecto.Migration

  def up do
    alter table(:cyclium_work_claims) do
      add(:fence, :integer, null: false, default: 0)
    end
  end

  def down do
    alter table(:cyclium_work_claims) do
      remove(:fence)
    end
  end
end

defmodule Cyclium.FindingsDbTest do
  @moduledoc """
  Integration tests for the Findings write path against a real SQLite database.

  FakeRepo.get_by always returns nil, so the {:raise} upsert, {:update}, and
  {:clear} paths are never meaningfully exercised by the existing test suite.
  These tests verify the full transaction-based lifecycle.
  """
  use Cyclium.DataCase

  alias Cyclium.Findings
  alias Cyclium.Schemas.Finding

  # Base finding params reused across tests.
  defp finding_params(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: "test_actor",
        finding_key: "test:finding:#{System.unique_integer([:positive])}",
        class: "test_class",
        severity: :high,
        confidence: 0.9,
        summary: "Test finding"
      },
      overrides
    )
  end

  describe "persist_finding {:raise}" do
    test "inserts a new active finding" do
      episode = insert_episode()
      params = finding_params()

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.status == :active
      assert finding.finding_key == params.finding_key
      assert finding.raised_by_episode_id == episode.id
      assert finding.confidence == 0.9
    end

    test "second raise on same key updates the existing finding (last-writer-wins)" do
      episode = insert_episode()
      params = finding_params()

      {:ok, first} = Findings.persist_finding({:raise, params}, episode)

      updated_params = Map.put(params, :confidence, 0.5)
      {:ok, second} = Findings.persist_finding({:raise, updated_params}, episode)

      # Same row updated, not a new row
      assert first.id == second.id
      assert second.confidence == 0.5
      assert Repo.aggregate(Finding, :count) == 1
    end

    test "re-raise after clear inserts a new active finding" do
      episode = insert_episode()
      params = finding_params()

      {:ok, _first} = Findings.persist_finding({:raise, params}, episode)
      {:ok, _} = Findings.persist_finding({:clear, params.finding_key}, episode)

      {:ok, second} = Findings.persist_finding({:raise, params}, episode)
      assert second.status == :active

      # Two rows: one cleared, one active
      assert Repo.aggregate(Finding, :count) == 2
    end

    test "denormalizes subject_kind and subject_id from subject map" do
      episode = insert_episode()

      params =
        finding_params(%{
          subject: %{kind: "order", id: "ORD-999"}
        })

      {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.subject_kind == "order"
      assert finding.subject_id == "ORD-999"
    end
  end

  describe "persist_finding {:update}" do
    test "updates allowed mutable fields on an active finding" do
      episode = insert_episode()
      params = finding_params()
      {:ok, _} = Findings.persist_finding({:raise, params}, episode)

      assert {:ok, updated} =
               Findings.persist_finding(
                 {:update, params.finding_key, %{confidence: 0.1, severity: :low}},
                 episode
               )

      assert updated.confidence == 0.1
      assert updated.severity == :low
    end

    test "returns :not_found when no active finding exists" do
      episode = insert_episode()

      assert {:error, :not_found} =
               Findings.persist_finding({:update, "nonexistent:key", %{confidence: 0.5}}, episode)
    end

    test "returns :not_found after finding has been cleared" do
      episode = insert_episode()
      params = finding_params()
      {:ok, _} = Findings.persist_finding({:raise, params}, episode)
      {:ok, _} = Findings.persist_finding({:clear, params.finding_key}, episode)

      assert {:error, :not_found} =
               Findings.persist_finding(
                 {:update, params.finding_key, %{confidence: 0.5}},
                 episode
               )
    end
  end

  describe "persist_finding {:clear}" do
    test "sets status to :cleared and records cleared_by_episode_id" do
      episode = insert_episode()
      params = finding_params()
      {:ok, _} = Findings.persist_finding({:raise, params}, episode)

      assert {:ok, cleared} = Findings.persist_finding({:clear, params.finding_key}, episode)
      assert cleared.status == :cleared
      assert cleared.cleared_by_episode_id == episode.id
      assert cleared.cleared_at != nil
    end

    test "stores reason in evidence_refs when provided" do
      episode = insert_episode()
      params = finding_params()
      {:ok, _} = Findings.persist_finding({:raise, params}, episode)

      assert {:ok, cleared} =
               Findings.persist_finding({:clear, params.finding_key, "resolved"}, episode)

      assert cleared.evidence_refs["cleared_reason"] == "resolved"
    end

    test "is idempotent — clearing an already-cleared finding returns :ok" do
      episode = insert_episode()
      params = finding_params()
      {:ok, _} = Findings.persist_finding({:raise, params}, episode)
      {:ok, _} = Findings.persist_finding({:clear, params.finding_key}, episode)

      # Second clear: finding no longer active, returns :ok
      assert :ok = Findings.persist_finding({:clear, params.finding_key}, episode)
    end

    test "returns :ok when finding never existed" do
      episode = insert_episode()
      assert :ok = Findings.persist_finding({:clear, "never:existed"}, episode)
    end
  end

  describe "ExpirationSweep.sweep_expired (DB)" do
    alias Cyclium.Findings.ExpirationSweep

    defp insert_finding(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      episode = insert_episode()

      defaults = %{
        actor_id: "test_actor",
        finding_key: "test:key:#{System.unique_integer([:positive])}",
        status: :active,
        class: "test",
        severity: :low,
        raised_by_episode_id: episode.id,
        raised_at: now,
        updated_at: now
      }

      %Finding{}
      |> Finding.changeset(Map.merge(defaults, Map.new(attrs)))
      |> Repo.insert!()
    end

    test "clears active findings past their expires_at" do
      expired = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      finding = insert_finding(%{expires_at: expired})

      assert ExpirationSweep.sweep_expired() > 0

      cleared = Repo.get!(Finding, finding.id)
      assert cleared.status == :cleared
    end

    test "does not clear active findings not yet expired" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      finding = insert_finding(%{expires_at: future})

      assert ExpirationSweep.sweep_expired() == 0

      still_active = Repo.get!(Finding, finding.id)
      assert still_active.status == :active
    end

    test "archives previously-cleared finding before clearing expired one with same key" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      key = "dup:key:#{System.unique_integer([:positive])}"

      # Insert an already-cleared finding with this key
      old_cleared =
        insert_finding(%{
          finding_key: key,
          status: :cleared,
          cleared_at: DateTime.add(now, -3600, :second)
        })

      # Insert an active finding with the same key that has expired
      expired_active =
        insert_finding(%{
          finding_key: key,
          status: :active,
          expires_at: DateTime.add(now, -60, :second)
        })

      # This would crash with unique_violation before the fix
      assert ExpirationSweep.sweep_expired() > 0

      # Old cleared finding should now be superseded and archived
      archived = Repo.get!(Finding, old_cleared.id)
      assert archived.status == :superseded
      assert not is_nil(archived.archived_at)

      # Expired active finding should now be cleared
      newly_cleared = Repo.get!(Finding, expired_active.id)
      assert newly_cleared.status == :cleared
    end
  end

  describe "Escalation.sweep scoped by (actor, expectation)" do
    alias Cyclium.Findings.Config
    alias Cyclium.Findings.Escalation

    setup do
      Config.ensure_table()
      :ets.delete_all_objects(:cyclium_findings_config)
      :ok
    end

    test "escalates only findings matching the registered actor + expectation" do
      old = DateTime.add(DateTime.utc_now(), -120 * 60, :second) |> DateTime.truncate(:second)

      # Actor A registers escalation for class "delay" → :high after 60 min
      Config.register("actor_a", "exp_a", %{
        escalation_rules: %{
          "delay" => [%{after_minutes: 60, escalate_to: :high}]
        }
      })

      # Finding from actor_a/exp_a — should be escalated
      f_a =
        insert_finding(%{
          actor_id: "actor_a",
          expectation_id: "exp_a",
          class: "delay",
          severity: :low,
          raised_at: old
        })

      # Finding from actor_b/exp_b with same class — should NOT be escalated
      f_b =
        insert_finding(%{
          actor_id: "actor_b",
          expectation_id: "exp_b",
          class: "delay",
          severity: :low,
          raised_at: old
        })

      assert Escalation.sweep() == 1

      assert Repo.get!(Finding, f_a.id).severity == :high
      assert Repo.get!(Finding, f_b.id).severity == :low
    end

    test "different actors can have different thresholds for the same class" do
      old = DateTime.add(DateTime.utc_now(), -120 * 60, :second) |> DateTime.truncate(:second)

      Config.register("actor_x", "exp_x", %{
        escalation_rules: %{
          "alert" => [%{after_minutes: 60, escalate_to: :high}]
        }
      })

      Config.register("actor_y", "exp_y", %{
        escalation_rules: %{
          "alert" => [%{after_minutes: 60, escalate_to: :critical}]
        }
      })

      f_x =
        insert_finding(%{
          actor_id: "actor_x",
          expectation_id: "exp_x",
          class: "alert",
          severity: :low,
          raised_at: old
        })

      f_y =
        insert_finding(%{
          actor_id: "actor_y",
          expectation_id: "exp_y",
          class: "alert",
          severity: :low,
          raised_at: old
        })

      assert Escalation.sweep() == 2

      assert Repo.get!(Finding, f_x.id).severity == :high
      assert Repo.get!(Finding, f_y.id).severity == :critical
    end

    test "findings without expectation_id are not escalated" do
      old = DateTime.add(DateTime.utc_now(), -120 * 60, :second) |> DateTime.truncate(:second)

      Config.register("actor_z", "exp_z", %{
        escalation_rules: %{
          "delay" => [%{after_minutes: 60, escalate_to: :high}]
        }
      })

      # Legacy finding with no expectation_id
      f =
        insert_finding(%{
          actor_id: "actor_z",
          class: "delay",
          severity: :low,
          raised_at: old
        })

      assert Escalation.sweep() == 0
      assert Repo.get!(Finding, f.id).severity == :low
    end
  end
end

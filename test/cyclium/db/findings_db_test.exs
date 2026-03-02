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
end

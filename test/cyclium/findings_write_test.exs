defmodule Cyclium.FindingsWriteTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
    end)

    episode = %Cyclium.Schemas.Episode{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      status: :running
    }

    %{episode: episode}
  end

  describe "persist_finding {:raise, params}" do
    test "inserts new active finding", %{episode: episode} do
      params = %{
        actor_id: "test_actor",
        finding_key: "test:raise:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :high,
        confidence: 0.95,
        summary: "Test finding",
        subject: %{kind: "po", id: "PO-100"},
        evidence_refs: %{"source" => "test"}
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.finding_key == params.finding_key
      assert finding.status == :active
      assert finding.raised_by_episode_id == episode.id
      assert finding.severity == :high
      assert finding.confidence == 0.95
    end

    test "emits :raised telemetry", %{episode: episode} do
      ref = make_ref()

      :telemetry.attach(
        "test-finding-raised-#{inspect(ref)}",
        [:cyclium, :finding, :raised],
        &Cyclium.TelemetryHelper.handle_event/4,
        %{test_pid: self()}
      )

      params = %{
        actor_id: "test_actor",
        finding_key: "test:telemetry:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :medium,
        confidence: 0.8,
        summary: "Telemetry test"
      }

      Findings.persist_finding({:raise, params}, episode)

      assert_receive {:telemetry, [:cyclium, :finding, :raised], %{count: 1}, meta}
      assert meta.class == "test_class"

      :telemetry.detach("test-finding-raised-#{inspect(ref)}")
    end
  end

  describe "persist_finding {:update, key, changes}" do
    test "returns :not_found when no active finding", %{episode: episode} do
      assert {:error, :not_found} =
               Findings.persist_finding({:update, "nonexistent-key", %{confidence: 0.99}}, episode)
    end
  end

  describe "persist_finding {:clear, key}" do
    test "returns :ok when finding does not exist (idempotent)", %{episode: episode} do
      assert :ok = Findings.persist_finding({:clear, "nonexistent-key"}, episode)
    end

    test "returns :ok with reason when finding does not exist", %{episode: episode} do
      assert :ok = Findings.persist_finding({:clear, "nonexistent-key", "stale"}, episode)
    end
  end
end

defmodule Cyclium.Findings.ExpirationSweepTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings
  alias Cyclium.Findings.ExpirationSweep

  setup do
    case Cyclium.FakeRepo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

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

  describe "ttl_seconds in persist_finding" do
    test "computes expires_at from ttl_seconds", %{episode: episode} do
      params = %{
        actor_id: "test_actor",
        finding_key: "ttl:#{Ecto.UUID.generate()}",
        class: "ttl_class",
        severity: :low,
        confidence: 0.7,
        summary: "TTL finding",
        ttl_seconds: 3600
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.expires_at != nil

      # expires_at should be ~1 hour from now
      diff = DateTime.diff(finding.expires_at, DateTime.utc_now(), :second)
      assert diff >= 3590 and diff <= 3610
    end

    test "does not override explicit expires_at", %{episode: episode} do
      explicit_expires = DateTime.utc_now() |> DateTime.add(7200) |> DateTime.truncate(:second)

      params = %{
        actor_id: "test_actor",
        finding_key: "ttl:explicit:#{Ecto.UUID.generate()}",
        class: "ttl_class",
        severity: :low,
        confidence: 0.7,
        summary: "Explicit expires",
        ttl_seconds: 3600,
        expires_at: explicit_expires
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.expires_at == explicit_expires
    end

    test "finding without ttl_seconds has nil expires_at", %{episode: episode} do
      params = %{
        actor_id: "test_actor",
        finding_key: "no_ttl:#{Ecto.UUID.generate()}",
        class: "no_ttl_class",
        severity: :medium,
        confidence: 0.8,
        summary: "No TTL"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.expires_at == nil
    end
  end

  describe "ExpirationSweep" do
    test "sweep_expired calls update_all and returns count" do
      # FakeRepo.update_all returns {0, nil}
      assert ExpirationSweep.sweep_expired() == 0
    end

    test "expired telemetry event is declared" do
      events = Cyclium.Telemetry.events()
      assert [:cyclium, :finding, :expired] in events
    end
  end
end

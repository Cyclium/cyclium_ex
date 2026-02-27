defmodule Cyclium.FindingsEnrichmentTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings

  setup do
    case Cyclium.FakeRepo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
    Cyclium.Findings.Config.ensure_table()

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
      Application.delete_env(:cyclium, :finding_enrichment)
    end)

    episode = %Cyclium.Schemas.Episode{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      status: :running
    }

    %{episode: episode}
  end

  describe "finding enrichment callback" do
    test "enriches finding when callback returns {:ok, map}", %{episode: episode} do
      Application.put_env(:cyclium, :finding_enrichment, fn finding, _episode ->
        {:ok, %{summary: "Enriched: #{finding.summary}", confidence: 0.99}}
      end)

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :high,
        confidence: 0.5,
        summary: "Original"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.summary == "Enriched: Original"
      assert finding.confidence == 0.99
    end

    test "skips enrichment when callback returns :skip", %{episode: episode} do
      Application.put_env(:cyclium, :finding_enrichment, fn _finding, _episode ->
        :skip
      end)

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:skip:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :medium,
        confidence: 0.7,
        summary: "Not enriched"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.summary == "Not enriched"
      assert finding.confidence == 0.7
    end

    test "handles callback errors gracefully", %{episode: episode} do
      Application.put_env(:cyclium, :finding_enrichment, fn _finding, _episode ->
        raise "boom"
      end)

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:error:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :low,
        confidence: 0.6,
        summary: "Should survive"
      }

      # Should not raise, finding persists unchanged
      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.summary == "Should survive"
    end

    test "no enrichment when callback not configured", %{episode: episode} do
      Application.delete_env(:cyclium, :finding_enrichment)

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:none:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :medium,
        confidence: 0.8,
        summary: "Plain finding"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.summary == "Plain finding"
    end

    test "supports {mod, fun} tuple callback", %{episode: episode} do
      defmodule TestEnricher do
        def enrich(finding, _episode) do
          {:ok, %{summary: "Module enriched: #{finding.summary}"}}
        end
      end

      Application.put_env(:cyclium, :finding_enrichment, {TestEnricher, :enrich})

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:mf:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :high,
        confidence: 0.9,
        summary: "Original"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.summary == "Module enriched: Original"
    end

    test "uses per-expectation enrichment from Findings.Config over app env", %{episode: episode} do
      # Set app env callback (should be overridden)
      Application.put_env(:cyclium, :finding_enrichment, fn _finding, _episode ->
        {:ok, %{summary: "From app env"}}
      end)

      # Register per-expectation enrichment
      Cyclium.Findings.Config.register("test_actor", "test_exp", %{
        enrichment: fn finding, _episode ->
          {:ok, %{summary: "From DSL: #{finding.summary}"}}
        end
      })

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:dsl:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :high,
        confidence: 0.5,
        summary: "Original"
      }

      assert {:ok, finding} = Cyclium.Findings.persist_finding({:raise, params}, episode)
      # Should use the per-expectation callback, not app env
      assert finding.summary == "From DSL: Original"
    end

    test "only allows safe fields in enrichment", %{episode: episode} do
      Application.put_env(:cyclium, :finding_enrichment, fn _finding, _episode ->
        {:ok, %{summary: "Safe", status: :cleared, actor_id: "hacked"}}
      end)

      params = %{
        actor_id: "test_actor",
        finding_key: "enrich:safe:#{Ecto.UUID.generate()}",
        class: "test_class",
        severity: :medium,
        confidence: 0.8,
        summary: "Before"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      # summary is allowed
      assert finding.summary == "Safe"
      # status and actor_id should NOT be changed by enrichment
      assert finding.status == :active
      assert finding.actor_id == "test_actor"
    end
  end
end

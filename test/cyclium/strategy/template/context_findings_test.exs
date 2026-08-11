defmodule Cyclium.Strategy.Template.ContextFindingsTest do
  @moduledoc """
  Tests for the shared context-findings loader that backs both strategy
  templates (Gap 1 + 4): scoping (:none default / :subject / :actor), the row
  limit, and the loaded/failed distinction.
  """
  use Cyclium.DataCase

  alias Cyclium.Findings
  alias Cyclium.Strategy.Template.Agentic.Loop

  @actor "context_findings_actor"

  defp ctx, do: %{actor_id: @actor, episode_id: Ecto.UUID.generate()}

  defp raise_finding(subject) do
    ep = insert_episode(%{actor_id: @actor})

    params = %{
      actor_id: @actor,
      finding_key: "cf:#{System.unique_integer([:positive])}",
      class: "margin_appraisal",
      severity: :low,
      confidence: 0.9,
      summary: "s",
      subject: subject
    }

    {:ok, _} = Findings.persist_finding({:raise, params}, ep)
  end

  describe "scoping mode" do
    test "defaults to :none — findings context is opt-in" do
      raise_finding(%{kind: "resource", id: "R-1"})

      assert {:ok, []} = Loop.load_context_findings(%{}, ctx(), %{"resource_id" => "R-1"})
    end

    test ":actor returns every active finding for the actor" do
      raise_finding(%{kind: "resource", id: "R-1"})
      raise_finding(%{kind: "resource", id: "R-2"})

      assert {:ok, findings} =
               Loop.load_context_findings(%{"context_findings" => "actor"}, ctx(), %{})

      assert length(findings) == 2
    end

    test ":subject returns only the episode's subject's findings" do
      raise_finding(%{kind: "resource", id: "R-1"})
      raise_finding(%{kind: "resource", id: "R-2"})

      config = %{
        "context_findings" => "subject",
        "finding_config" => %{"subject_kind" => "resource", "subject_id_key" => "resource_id"}
      }

      assert {:ok, [%{"subject_id" => "R-1"}]} =
               Loop.load_context_findings(config, ctx(), %{"resource_id" => "R-1"})
    end

    test ":subject resolves the id via an atom-keyed lookup too" do
      raise_finding(%{kind: "resource", id: "R-1"})

      config = %{
        "context_findings" => "subject",
        "finding_config" => %{"subject_kind" => "resource", "subject_id_key" => "resource_id"}
      }

      assert {:ok, [%{"subject_id" => "R-1"}]} =
               Loop.load_context_findings(config, ctx(), %{resource_id: "R-1"})
    end

    test ":subject with an unresolvable subject errors instead of leaking everything" do
      raise_finding(%{kind: "resource", id: "R-1"})

      config = %{
        "context_findings" => "subject",
        "finding_config" => %{"subject_kind" => "resource", "subject_id_key" => "resource_id"}
      }

      assert {:error, {:subject_unresolved, "resource_id"}} =
               Loop.load_context_findings(config, ctx(), %{})
    end

    test ":subject without subject_kind/id_key is a configuration error" do
      config = %{"context_findings" => "subject"}

      assert {:error, {:subject_scoping_misconfigured, _}} =
               Loop.load_context_findings(config, ctx(), %{"resource_id" => "R-1"})
    end
  end

  describe "limit (Gap 4)" do
    test "context_findings_limit bounds the row count" do
      for _ <- 1..5, do: raise_finding(%{kind: "resource", id: "R-#{System.unique_integer()}"})

      config = %{"context_findings" => "actor", "context_findings_limit" => 3}
      assert {:ok, findings} = Loop.load_context_findings(config, ctx(), %{})
      assert length(findings) == 3
    end
  end
end

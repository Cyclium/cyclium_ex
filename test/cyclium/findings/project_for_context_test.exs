defmodule Cyclium.Findings.ProjectForContextTest do
  use ExUnit.Case, async: true

  alias Cyclium.Findings
  alias Cyclium.Schemas.Finding

  defp finding(overrides \\ %{}) do
    Map.merge(
      %Finding{
        actor_id: "actor",
        expectation_id: "exp",
        finding_key: "over_limit:R-1",
        status: :active,
        class: "over_limit",
        severity: :high,
        confidence: 0.9,
        summary: "resource over limit",
        subject: %{"kind" => "resource", "id" => "R-1"},
        subject_kind: "resource",
        subject_id: "R-1",
        evidence_refs: %{"narrative" => String.duplicate("x", 5_000)}
      },
      overrides
    )
  end

  test "projects a finding to a compact string-keyed map" do
    projected = Findings.project_finding(finding())

    assert projected == %{
             "finding_key" => "over_limit:R-1",
             "class" => "over_limit",
             "status" => "active",
             "severity" => "high",
             "confidence" => 0.9,
             "summary" => "resource over limit",
             "subject_kind" => "resource",
             "subject_id" => "R-1"
           }
  end

  test "the projection is JSON-encodable (the raw struct is not)" do
    f = finding()

    # The raw Ecto struct crashes the journal insert — this is the original bug.
    assert {:error, _} = Jason.encode(f)

    # The projection encodes cleanly, which is what unblocks context assembly.
    assert {:ok, _json} = Jason.encode(Findings.project_finding(f))
  end

  test "drops the heavy evidence_refs narrative from context" do
    projected = Findings.project_finding(finding())
    refute Map.has_key?(projected, "evidence_refs")
  end

  test "project_for_context maps a list and tolerates nil enum fields" do
    projected = Findings.project_for_context([finding(%{severity: nil})])

    assert [%{"severity" => nil, "status" => "active"}] = projected
    assert {:ok, _} = Jason.encode(projected)
  end
end

defmodule Cyclium.ConvergeResultTest do
  use ExUnit.Case

  alias Cyclium.ConvergeResult

  test "default struct has empty collections" do
    result = %ConvergeResult{}
    assert result.outputs == []
    assert result.findings == []
    assert result.summary == ""
    assert result.classification == nil
    assert result.confidence == nil
  end

  test "struct accepts all fields" do
    result = %ConvergeResult{
      outputs: [%Cyclium.OutputProposal{type: :email, dedupe_key: "test", payload: %{}}],
      findings: [{:raise, %{finding_key: "po_stalled:PO-1955", class: "vendor_delay"}}],
      summary: "1 PO reviewed",
      classification: %{primary: "vendor_delay"},
      confidence: 0.85
    }

    assert length(result.outputs) == 1
    assert length(result.findings) == 1
    assert result.summary == "1 PO reviewed"
    assert result.classification.primary == "vendor_delay"
    assert result.confidence == 0.85
  end
end

defmodule Cyclium.OutputProposalTest do
  use ExUnit.Case

  alias Cyclium.OutputProposal

  test "default requires_approval is false" do
    proposal = %OutputProposal{type: :email, dedupe_key: "test", payload: %{}}
    assert proposal.requires_approval == false
  end

  test "struct accepts all fields" do
    proposal = %OutputProposal{
      type: :slack,
      dedupe_key: "slack:po_sla:2026-02-23T12",
      payload: %{channel: "#ops", message: "3 POs reviewed"},
      requires_approval: true
    }

    assert proposal.type == :slack
    assert proposal.dedupe_key == "slack:po_sla:2026-02-23T12"
    assert proposal.payload.channel == "#ops"
    assert proposal.requires_approval == true
  end
end

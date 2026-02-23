defmodule Cyclium.ExpectationTest do
  use ExUnit.Case

  alias Cyclium.Expectation

  test "struct has sensible defaults" do
    exp = %Expectation{id: :test, actor_id: :my_actor, domain: :ops, trigger: {:schedule, 5000}}

    assert exp.subscribes_to == []
    assert exp.filter == %{}
    assert exp.debounce_ms == nil
    assert exp.cooldown_ms == nil
    assert exp.resources == []
    assert exp.outputs == []
    assert exp.budget == %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}
    assert exp.log_strategy == :timeline
    assert exp.audit_level == :standard
    assert exp.retention_days == 30
    assert exp.description == ""
    assert exp.synthesizer == nil
  end

  test "struct accepts all fields" do
    exp = %Expectation{
      id: :po_sla,
      actor_id: :po_status,
      domain: :procurement,
      trigger: {:schedule, :timer.hours(4)},
      subscribes_to: ["po.created", "po.status_changed"],
      filter: %{status: {:in, ["OPEN", "STALLED"]}},
      debounce_ms: 60_000,
      cooldown_ms: 600_000,
      resources: [%{kind: :erp_module, ref: "purchase_orders", access: :read}],
      outputs: [:email, :slack],
      budget: %{max_turns: 15, max_tokens: 30_000, max_wall_ms: 180_000},
      log_strategy: :full_debug,
      audit_level: :detailed,
      retention_days: 90,
      description: "Check PO SLA compliance",
      synthesizer: SomeSynthesizer
    }

    assert exp.id == :po_sla
    assert exp.debounce_ms == 60_000
    assert exp.synthesizer == SomeSynthesizer
    assert length(exp.subscribes_to) == 2
  end
end

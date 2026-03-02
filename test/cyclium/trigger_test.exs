defmodule Cyclium.TriggerTest do
  use ExUnit.Case

  alias Cyclium.Trigger

  test "Schedule struct has scheduled_at field" do
    now = DateTime.utc_now()
    trigger = %Trigger.Schedule{scheduled_at: now}
    assert trigger.scheduled_at == now
  end

  test "Event struct has all fields" do
    trigger = %Trigger.Event{
      event_id: "evt-123",
      event_type: "po.status_changed",
      entity_id: "PO-1955",
      payload: %{new_status: "STALLED"}
    }

    assert trigger.event_id == "evt-123"
    assert trigger.event_type == "po.status_changed"
    assert trigger.entity_id == "PO-1955"
    assert trigger.payload == %{new_status: "STALLED"}
  end

  test "Manual struct has requested_by and reason" do
    trigger = %Trigger.Manual{
      requested_by: "admin@example.com",
      reason: "Investigating anomaly"
    }

    assert trigger.requested_by == "admin@example.com"
    assert trigger.reason == "Investigating anomaly"
  end

  test "Workflow struct has workflow fields and input" do
    trigger = %Trigger.Workflow{
      workflow_instance_id: "wf-001",
      workflow_step_id: "compliance_check",
      input: %{vendor_id: "V-123"}
    }

    assert trigger.workflow_instance_id == "wf-001"
    assert trigger.workflow_step_id == "compliance_check"
    assert trigger.input == %{vendor_id: "V-123"}
  end
end

defmodule Cyclium.Schemas.EpisodeTest do
  use ExUnit.Case

  alias Cyclium.Schemas.Episode

  test "changeset validates required fields" do
    changeset = Episode.changeset(%Episode{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset, :actor_id)
    assert "can't be blank" in errors_on(changeset, :expectation_id)
    assert "can't be blank" in errors_on(changeset, :trigger_type)
    # status has a default of :running so it won't be blank
    assert "can't be blank" in errors_on(changeset, :started_at)
  end

  test "changeset accepts valid attrs" do
    attrs = %{
      actor_id: "po_status",
      expectation_id: "po_delivery_sla",
      trigger_type: :schedule,
      status: :running,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      budget: %{"max_turns" => 12, "max_tokens" => 25_000, "max_wall_ms" => 120_000}
    }

    changeset = Episode.changeset(%Episode{}, attrs)
    assert changeset.valid?
  end

  test "changeset accepts all optional fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      actor_id: "po_status",
      expectation_id: "po_delivery_sla",
      trigger_type: :event,
      trigger_ref: %{event_id: "evt-1", event_type: "po.status_changed"},
      dedupe_key: "po_status:po_delivery_sla:2026-02-23",
      status: :running,
      phase: "gather",
      budget: %{"max_turns" => 12},
      turns_used: 3,
      tokens_used: 1500,
      attempts: 1,
      max_attempts: 3,
      classification: %{primary: "vendor_delay"},
      confidence: 0.85,
      summary: "Investigated PO delays",
      log_strategy: "timeline",
      error_class: nil,
      error_detail: nil,
      workflow_instance_id: nil,
      workflow_step_id: nil,
      started_at: now,
      finished_at: nil,
      queued_at: nil
    }

    changeset = Episode.changeset(%Episode{}, attrs)
    assert changeset.valid?
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end

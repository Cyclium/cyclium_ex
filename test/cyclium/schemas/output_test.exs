defmodule Cyclium.Schemas.OutputTest do
  use ExUnit.Case

  alias Cyclium.Schemas.Output

  test "changeset validates required fields" do
    changeset = Output.changeset(%Output{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset, :episode_id)
    assert "can't be blank" in errors_on(changeset, :type)
    assert "can't be blank" in errors_on(changeset, :dedupe_key)
    # status has a default of :proposed so it won't be blank
    assert "can't be blank" in errors_on(changeset, :created_at)
  end

  test "changeset accepts valid output" do
    attrs = %{
      episode_id: Ecto.UUID.generate(),
      type: "email",
      dedupe_key: "email:inquiry:PO-1955:V-ACME:2026-02-23",
      status: :proposed,
      payload_redacted: %{to: "jane@acme.com", subject: "Following up: PO-1955"},
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = Output.changeset(%Output{}, attrs)
    assert changeset.valid?
  end

  test "changeset accepts delivered output with ref" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      episode_id: Ecto.UUID.generate(),
      type: "slack",
      dedupe_key: "slack:po_sla:2026-02-23T12",
      status: :delivered,
      payload_redacted: %{channel: "#ops"},
      delivered_ref: %{slack_ts: "1234567890.123456"},
      delivered_at: now,
      created_at: now
    }

    changeset = Output.changeset(%Output{}, attrs)
    assert changeset.valid?
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end

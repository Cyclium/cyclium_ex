defmodule Cyclium.Schemas.FindingTest do
  use ExUnit.Case

  alias Cyclium.Schemas.Finding

  test "changeset validates required fields" do
    changeset = Finding.changeset(%Finding{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset, :actor_id)
    assert "can't be blank" in errors_on(changeset, :finding_key)
    assert "can't be blank" in errors_on(changeset, :class)
    assert "can't be blank" in errors_on(changeset, :raised_by_episode_id)
    assert "can't be blank" in errors_on(changeset, :raised_at)
  end

  test "changeset accepts valid attrs" do
    attrs = %{
      actor_id: "po_status",
      finding_key: "po_stalled:PO-1955",
      status: :active,
      class: "vendor_delay",
      severity: :high,
      confidence: 0.85,
      subject: %{"kind" => "po", "id" => "PO-1955"},
      summary: "PO-1955 stalled 22 days",
      raised_by_episode_id: Ecto.UUID.generate(),
      raised_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = Finding.changeset(%Finding{}, attrs)
    assert changeset.valid?
  end

  test "changeset denormalizes subject fields from string-keyed map" do
    attrs = %{
      actor_id: "po_status",
      finding_key: "po_stalled:PO-1955",
      class: "vendor_delay",
      subject: %{"kind" => "po", "id" => "PO-1955"},
      raised_by_episode_id: Ecto.UUID.generate(),
      raised_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = Finding.changeset(%Finding{}, attrs)
    assert Ecto.Changeset.get_change(changeset, :subject_kind) == "po"
    assert Ecto.Changeset.get_change(changeset, :subject_id) == "PO-1955"
  end

  test "changeset denormalizes subject fields from atom-keyed map" do
    attrs = %{
      actor_id: "po_status",
      finding_key: "test:123",
      class: "test",
      subject: %{kind: :vendor, id: "V-ACME"},
      raised_by_episode_id: Ecto.UUID.generate(),
      raised_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = Finding.changeset(%Finding{}, attrs)
    assert Ecto.Changeset.get_change(changeset, :subject_kind) == "vendor"
    assert Ecto.Changeset.get_change(changeset, :subject_id) == "V-ACME"
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end

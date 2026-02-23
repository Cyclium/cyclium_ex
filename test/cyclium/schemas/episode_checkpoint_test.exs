defmodule Cyclium.Schemas.EpisodeCheckpointTest do
  use ExUnit.Case

  alias Cyclium.Schemas.EpisodeCheckpoint

  test "changeset validates required fields" do
    changeset = EpisodeCheckpoint.changeset(%EpisodeCheckpoint{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset, :episode_id)
    assert "can't be blank" in errors_on(changeset, :checkpoint_no)
    assert "can't be blank" in errors_on(changeset, :phase)
    assert "can't be blank" in errors_on(changeset, :schema_version)
    assert "can't be blank" in errors_on(changeset, :state)
    assert "can't be blank" in errors_on(changeset, :created_at)
  end

  test "changeset accepts valid checkpoint" do
    attrs = %{
      episode_id: Ecto.UUID.generate(),
      checkpoint_no: 1,
      phase: "classify",
      schema_version: 1,
      state: %{po_batch: ["PO-1847", "PO-1955"], phase: "classify"},
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = EpisodeCheckpoint.changeset(%EpisodeCheckpoint{}, attrs)
    assert changeset.valid?
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end

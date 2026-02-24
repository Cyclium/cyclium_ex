defmodule Cyclium.Schemas.EpisodeStepTest do
  use ExUnit.Case

  alias Cyclium.Schemas.EpisodeStep

  test "changeset validates required fields" do
    changeset = EpisodeStep.changeset(%EpisodeStep{}, %{})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset, :episode_id)
    assert "can't be blank" in errors_on(changeset, :step_no)
    assert "can't be blank" in errors_on(changeset, :kind)
    assert "can't be blank" in errors_on(changeset, :created_at)
  end

  test "changeset accepts valid tool_call step" do
    attrs = %{
      episode_id: Ecto.UUID.generate(),
      step_no: 1,
      kind: :tool_call,
      tool_name: "erp_read.search_pos",
      args_hash: "sha256-abc123",
      args_redacted: %{status: ["OPEN", "PARTIAL"]},
      result_ref: %{count: 3},
      cost_tokens: 0,
      cost_ms: 450,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = EpisodeStep.changeset(%EpisodeStep{}, attrs)
    assert changeset.valid?
  end

  test "changeset accepts all step kinds" do
    kinds = [
      :tool_call,
      :synthesis,
      :observation,
      :checkpoint,
      :output_proposed,
      :output_delivered,
      :output_failed,
      :approval_requested,
      :approval_resolved,
      :wait_started,
      :wait_resolved,
      :finding_raised,
      :finding_cleared,
      :episode_completed,
      :episode_failed
    ]

    for kind <- kinds do
      attrs = %{
        episode_id: Ecto.UUID.generate(),
        step_no: 1,
        kind: kind,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = EpisodeStep.changeset(%EpisodeStep{}, attrs)
      assert changeset.valid?, "Expected kind #{kind} to be valid"
    end
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end

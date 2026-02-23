defmodule Cyclium.LogProjectorTest do
  use ExUnit.Case

  alias Cyclium.LogProjector
  alias Cyclium.Schemas.EpisodeStep

  describe "render_steps/3 :timeline" do
    test "renders tool_call step" do
      steps = [
        %EpisodeStep{
          step_no: 1,
          kind: :tool_call,
          tool_name: "erp.search_pos",
          created_at: ~U[2026-02-23 14:00:00Z]
        }
      ]

      result = LogProjector.render_steps(steps, :timeline)
      assert result == "[14:00] erp.search_pos()"
    end

    test "renders multiple step types" do
      steps = [
        %EpisodeStep{
          step_no: 1,
          kind: :tool_call,
          tool_name: "erp.search_pos",
          created_at: ~U[2026-02-23 14:00:00Z]
        },
        %EpisodeStep{
          step_no: 2,
          kind: :finding_raised,
          created_at: ~U[2026-02-23 14:01:00Z]
        },
        %EpisodeStep{
          step_no: 3,
          kind: :output_delivered,
          tool_name: "email",
          created_at: ~U[2026-02-23 14:02:00Z]
        },
        %EpisodeStep{
          step_no: 4,
          kind: :episode_completed,
          created_at: ~U[2026-02-23 14:03:00Z]
        }
      ]

      result = LogProjector.render_steps(steps, :timeline)
      lines = String.split(result, "\n")

      assert length(lines) == 4
      assert Enum.at(lines, 0) =~ "erp.search_pos()"
      assert Enum.at(lines, 1) =~ "Finding raised"
      assert Enum.at(lines, 2) =~ "Output delivered: email"
      assert Enum.at(lines, 3) =~ "Episode completed"
    end

    test "renders output_failed with error class" do
      steps = [
        %EpisodeStep{
          step_no: 1,
          kind: :output_failed,
          tool_name: "slack",
          error_class: "adapter_error",
          created_at: ~U[2026-02-23 14:05:00Z]
        }
      ]

      result = LogProjector.render_steps(steps, :timeline)
      assert result =~ "Output failed: slack (adapter_error)"
    end

    test "renders episode_failed with error class" do
      steps = [
        %EpisodeStep{
          step_no: 1,
          kind: :episode_failed,
          error_class: "budget_exceeded",
          created_at: ~U[2026-02-23 14:05:00Z]
        }
      ]

      result = LogProjector.render_steps(steps, :timeline)
      assert result =~ "Episode failed (budget_exceeded)"
    end
  end

  describe "render_steps/3 :summary_only" do
    test "renders summary with step count" do
      episode = %Cyclium.Schemas.Episode{
        actor_id: "po_status",
        status: :done
      }

      steps = [
        %EpisodeStep{step_no: 1, kind: :tool_call, created_at: ~U[2026-02-23 14:00:00Z]},
        %EpisodeStep{step_no: 2, kind: :episode_completed, created_at: ~U[2026-02-23 14:01:00Z]}
      ]

      result = LogProjector.render_steps(steps, :summary_only, episode)
      assert result =~ "po_status"
      assert result =~ "done"
      assert result =~ "2 steps"
    end

    test "renders summary with no steps" do
      episode = %Cyclium.Schemas.Episode{actor_id: "test", status: :done}
      result = LogProjector.render_steps([], :summary_only, episode)
      assert result =~ "test"
      assert result =~ "done"
    end
  end

  describe "render_steps/3 :full_debug" do
    test "includes args and result" do
      steps = [
        %EpisodeStep{
          step_no: 1,
          kind: :tool_call,
          tool_name: "erp.search_pos",
          args_redacted: %{"status" => ["OPEN"]},
          result_ref: %{"count" => 3},
          created_at: ~U[2026-02-23 14:00:00Z]
        }
      ]

      result = LogProjector.render_steps(steps, :full_debug)
      assert result =~ "erp.search_pos()"
      assert result =~ "args:"
      assert result =~ "OPEN"
      assert result =~ "result:"
      assert result =~ "count"
    end
  end

  describe "render_steps/3 :none" do
    test "returns empty string" do
      steps = [%EpisodeStep{step_no: 1, kind: :tool_call, created_at: ~U[2026-02-23 14:00:00Z]}]
      assert LogProjector.render_steps(steps, :none) == ""
    end
  end
end

defmodule Cyclium.LogProjectorRenderStrategyDbTest do
  @moduledoc """
  Verifies that the rendered-log verbosity (`render_log_strategy`, an expectation
  override in persistent_term) is resolved independently of the episode's
  `log_strategy`, which still drives what step data is journaled.
  """
  use Cyclium.DataCase

  alias Cyclium.LogProjector
  alias Cyclium.Schemas.EpisodeLog

  defp log_content(episode_id) do
    Repo.get_by(EpisodeLog, episode_id: episode_id).content
  end

  defp tool_step(episode_id) do
    insert_step(%{
      episode_id: episode_id,
      step_no: 1,
      kind: :tool_call,
      tool_name: "erp.search",
      args_redacted: %{"q" => "x"},
      result_ref: %{"count" => 1}
    })
  end

  describe "project/1 render_log_strategy override" do
    test "renders at log_strategy verbosity when no override is set" do
      ep =
        insert_episode(%{
          actor_id: "rl_actor_a",
          expectation_id: "rl_exp_a",
          log_strategy: "full_debug"
        })

      tool_step(ep.id)

      assert {:ok, _} = LogProjector.project(ep.id)
      # full_debug includes raw args/results.
      assert log_content(ep.id) =~ "args:"
    end

    test "render_log_strategy overrides render verbosity independently of log_strategy" do
      key = {:cyclium_expectation_render_log_strategy, :rl_actor_b, :rl_exp_b}
      :persistent_term.put(key, :summary_only)
      on_exit(fn -> :persistent_term.erase(key) end)

      ep =
        insert_episode(%{
          actor_id: "rl_actor_b",
          expectation_id: "rl_exp_b",
          status: :done,
          # journaling stays full_debug; only rendering is overridden to summary
          log_strategy: "full_debug"
        })

      tool_step(ep.id)

      assert {:ok, _} = LogProjector.project(ep.id)
      content = log_content(ep.id)
      assert content =~ "[Summary]"
      refute content =~ "args:"
    end
  end
end

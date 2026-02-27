defmodule Cyclium.Test.Factories do
  @moduledoc """
  Shared factory functions for building test structs without a database.
  """

  alias Cyclium.Schemas.{AgentDefinition, WorkflowDefinition}

  def build_agent_definition(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = %AgentDefinition{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor_#{System.unique_integer([:positive])}",
      domain: "test",
      config: Jason.encode!(%{"log_strategy" => "full_debug"}),
      expectations:
        Jason.encode!([
          %{
            id: "default_exp",
            trigger: %{type: "event", event_type: "test.trigger"},
            log_strategy: "full_debug"
          }
        ]),
      strategy_ref: nil,
      strategy_template: "observe_synthesize_converge",
      strategy_config: Jason.encode!(%{}),
      enabled: true,
      inserted_at: now,
      updated_at: now
    }

    Map.merge(defaults, overrides)
  end

  def build_workflow_definition(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = %WorkflowDefinition{
      id: Ecto.UUID.generate(),
      workflow_id: "test_workflow_#{System.unique_integer([:positive])}",
      trigger_type: "event",
      trigger_event: "test.workflow.start",
      steps:
        Jason.encode!([
          %{id: "step_1", actor_id: "actor_a", expectation_id: "exp_a"},
          %{id: "step_2", actor_id: "actor_b", expectation_id: "exp_b", depends_on: ["step_1"]}
        ]),
      failure_policies: nil,
      enabled: true,
      created_at: now,
      updated_at: now
    }

    Map.merge(defaults, overrides)
  end
end

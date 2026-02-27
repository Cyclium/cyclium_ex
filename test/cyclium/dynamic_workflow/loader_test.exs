defmodule Cyclium.DynamicWorkflow.LoaderTest do
  use ExUnit.Case, async: true

  alias Cyclium.Workflow.{Config, StepConfig}

  # We test the config-building logic by calling the loader's internal
  # build_config via a test helper that replicates it. The actual DB
  # integration requires the test repo setup from workflow_engine_test.

  describe "config building from definition data" do
    test "builds valid Config from step JSON" do
      steps_json =
        Jason.encode!([
          %{
            "id" => "validate",
            "actor_id" => "validator_actor",
            "expectation" => "check_order",
            "depends_on" => [],
            "input_map" => %{"order_id" => "trigger.order_id"},
            "failure_policy" => "abort"
          },
          %{
            "id" => "fulfill",
            "actor_id" => "fulfillment_actor",
            "expectation" => "process_order",
            "depends_on" => ["validate"],
            "input_map" => %{
              "order_id" => "trigger.order_id",
              "validated" => "prior.validate.classification"
            },
            "failure_policy" => "retry",
            "max_step_attempts" => 3,
            "backoff_ms" => 5000
          }
        ])

      defn = %Cyclium.Schemas.WorkflowDefinition{
        workflow_id: "order_flow",
        trigger_type: "event",
        trigger_event: "order.created",
        steps: steps_json,
        failure_policies: nil,
        enabled: true
      }

      {:ok, config, input_maps} = build_test_config(defn)

      assert config.workflow_id == "dynamic:order_flow"
      assert config.trigger == {:event, "order.created"}

      # Steps
      assert Map.has_key?(config.steps, :validate)
      assert Map.has_key?(config.steps, :fulfill)

      validate_step = config.steps[:validate]
      assert validate_step.actor == "validator_actor"
      assert validate_step.expectation == :check_order
      assert validate_step.depends_on == []

      fulfill_step = config.steps[:fulfill]
      assert fulfill_step.actor == "fulfillment_actor"
      assert fulfill_step.expectation == :process_order
      assert fulfill_step.depends_on == [:validate]

      # Input maps
      assert input_maps[:validate] == %{"order_id" => "trigger.order_id"}

      assert input_maps[:fulfill] == %{
               "order_id" => "trigger.order_id",
               "validated" => "prior.validate.classification"
             }

      # Failure policies
      assert config.failure_policies[:validate] == %{policy: :abort}
      assert config.failure_policies[:fulfill].policy == :retry
      assert config.failure_policies[:fulfill].max_step_attempts == 3
      assert config.failure_policies[:fulfill].backoff_ms == 5000
    end

    test "manual trigger type" do
      defn = %Cyclium.Schemas.WorkflowDefinition{
        workflow_id: "manual_flow",
        trigger_type: "manual",
        trigger_event: nil,
        steps: Jason.encode!([%{"id" => "step_a", "actor_id" => "act", "expectation" => "exp"}]),
        failure_policies: nil,
        enabled: true
      }

      {:ok, config, _} = build_test_config(defn)
      assert config.trigger == :manual
    end

    test "detects circular dependencies" do
      defn = %Cyclium.Schemas.WorkflowDefinition{
        workflow_id: "cyclic",
        trigger_type: "manual",
        trigger_event: nil,
        steps:
          Jason.encode!([
            %{"id" => "a", "actor_id" => "act", "expectation" => "exp", "depends_on" => ["b"]},
            %{"id" => "b", "actor_id" => "act", "expectation" => "exp", "depends_on" => ["a"]}
          ]),
        failure_policies: nil,
        enabled: true
      }

      assert {:error, {:circular_dependency, _}} = build_test_config(defn)
    end

    test "steps with no input_map" do
      defn = %Cyclium.Schemas.WorkflowDefinition{
        workflow_id: "no_input",
        trigger_type: "manual",
        trigger_event: nil,
        steps:
          Jason.encode!([
            %{"id" => "step_a", "actor_id" => "act", "expectation" => "exp"}
          ]),
        failure_policies: nil,
        enabled: true
      }

      {:ok, _config, input_maps} = build_test_config(defn)
      assert input_maps == %{}
    end

    test "top-level failure_policies override step-level" do
      defn = %Cyclium.Schemas.WorkflowDefinition{
        workflow_id: "override_flow",
        trigger_type: "manual",
        trigger_event: nil,
        steps:
          Jason.encode!([
            %{
              "id" => "step_a",
              "actor_id" => "act",
              "expectation" => "exp",
              "failure_policy" => "abort"
            }
          ]),
        failure_policies:
          Jason.encode!(%{
            "step_a" => %{"policy" => "retry", "max_step_attempts" => 5}
          }),
        enabled: true
      }

      {:ok, config, _} = build_test_config(defn)

      # Top-level overrides step-level (Map.merge puts top-level last)
      assert config.failure_policies[:step_a].policy == :retry
      assert config.failure_policies[:step_a].max_step_attempts == 5
    end
  end

  describe "WorkflowDefinition schema" do
    test "struct has expected fields" do
      defn = %Cyclium.Schemas.WorkflowDefinition{}
      assert Map.has_key?(defn, :workflow_id)
      assert Map.has_key?(defn, :trigger_type)
      assert Map.has_key?(defn, :trigger_event)
      assert Map.has_key?(defn, :steps)
      assert Map.has_key?(defn, :failure_policies)
      assert Map.has_key?(defn, :enabled)
      assert defn.enabled == true
    end
  end

  # Replicate the build_config logic from the Loader for testing
  # (since it's private and requires no DB)

  defp build_test_config(defn) do
    alias Cyclium.Workflow.DAG

    steps_raw = Jason.decode!(defn.steps)

    trigger =
      case defn.trigger_type do
        "event" -> {:event, defn.trigger_event}
        "manual" -> :manual
      end

    {step_configs, input_maps} =
      Enum.reduce(steps_raw, {%{}, %{}}, fn step, {configs, maps} ->
        id = String.to_atom(step["id"])

        step_config = %StepConfig{
          id: id,
          actor: step["actor_id"],
          expectation: String.to_atom(step["expectation"]),
          input_fn: nil,
          input_map: step["input_map"],
          depends_on: Enum.map(step["depends_on"] || [], &String.to_atom/1),
          requires_approval: step["requires_approval"] || false
        }

        configs = Map.put(configs, id, step_config)
        maps = if step["input_map"], do: Map.put(maps, id, step["input_map"]), else: maps

        {configs, maps}
      end)

    failure_policies =
      steps_raw
      |> Enum.filter(& &1["failure_policy"])
      |> Enum.map(fn step ->
        id = String.to_atom(step["id"])
        policy = %{policy: String.to_atom(step["failure_policy"])}

        policy =
          if step["max_step_attempts"],
            do: Map.put(policy, :max_step_attempts, step["max_step_attempts"]),
            else: policy

        policy =
          if step["backoff_ms"],
            do: Map.put(policy, :backoff_ms, step["backoff_ms"]),
            else: policy

        {id, policy}
      end)
      |> Enum.into(%{})

    top_policies =
      case defn.failure_policies do
        nil -> %{}
        json when is_binary(json) -> Jason.decode!(json)
        m when is_map(m) -> m
      end

    top_policies_atomized =
      top_policies
      |> Enum.map(fn {k, v} ->
        {String.to_atom(k), atomize_policy(v)}
      end)
      |> Enum.into(%{})

    all_policies = Map.merge(failure_policies, top_policies_atomized)

    adjacency = Map.new(step_configs, fn {id, sc} -> {id, sc.depends_on} end)

    case DAG.validate!(adjacency) do
      :ok ->
        config = %Config{
          workflow_id: "dynamic:#{defn.workflow_id}",
          trigger: trigger,
          steps: step_configs,
          failure_policies: all_policies
        }

        {:ok, config, input_maps}

      {:error, {:cycle, node}} ->
        {:error, {:circular_dependency, node}}
    end
  end

  defp atomize_policy(policy) when is_map(policy) do
    base = %{policy: String.to_atom(policy["policy"] || "abort")}

    base =
      if policy["max_step_attempts"],
        do: Map.put(base, :max_step_attempts, policy["max_step_attempts"]),
        else: base

    if policy["backoff_ms"],
      do: Map.put(base, :backoff_ms, policy["backoff_ms"]),
      else: base
  end
end

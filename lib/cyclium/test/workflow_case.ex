defmodule Cyclium.Test.WorkflowCase do
  @moduledoc """
  Test helpers for validating workflow definitions.

  Checks DAG validity, step input functions, failure policy coverage,
  and structural correctness for both compiled and dynamic workflows.

  ## Usage

      defmodule MyApp.Workflows.VendorOnboardingTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.WorkflowCase

        test "workflow is valid" do
          assert_valid_workflow(MyApp.Workflows.VendorOnboarding)
        end

        test "step inputs don't crash" do
          assert_step_inputs_safe(MyApp.Workflows.VendorOnboarding,
            trigger: %{"vendor_id" => "v123"}
          )
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.WorkflowCase
    end
  end

  @doc """
  Assert that a workflow module has a valid definition: trigger set,
  steps form a DAG, no duplicate IDs, all depends_on references exist.
  """
  defmacro assert_valid_workflow(workflow_module) do
    quote bind_quoted: [workflow_module: workflow_module] do
      Cyclium.Test.WorkflowCase.validate_workflow!(workflow_module)
    end
  end

  @doc """
  Assert that all failure policies reference existing steps and use
  valid policy types.
  """
  defmacro assert_failure_policies_valid(workflow_module) do
    quote bind_quoted: [workflow_module: workflow_module] do
      Cyclium.Test.WorkflowCase.validate_failure_policies!(workflow_module)
    end
  end

  @doc """
  Assert that every step has a failure policy defined. Useful for
  enforcing that teams explicitly handle failures for all steps.
  """
  defmacro assert_failure_policies_complete(workflow_module) do
    quote bind_quoted: [workflow_module: workflow_module] do
      Cyclium.Test.WorkflowCase.validate_failure_policies_complete!(workflow_module)
    end
  end

  @doc """
  Assert that all step input functions execute without crashing for
  the given trigger payload. Uses empty prior results for root steps
  and mock prior results for dependent steps.

  ## Options

    * `:trigger` — trigger payload map (required)
    * `:prior` — mock prior step results (default: auto-generated empty maps)
  """
  defmacro assert_step_inputs_safe(workflow_module, opts) do
    quote bind_quoted: [workflow_module: workflow_module, opts: opts] do
      Cyclium.Test.WorkflowCase.validate_step_inputs!(workflow_module, opts)
    end
  end

  # --- Implementation functions ---

  @doc false
  def validate_workflow!(workflow_module) do
    Code.ensure_loaded!(workflow_module)

    unless function_exported?(workflow_module, :__workflow_config__, 0) do
      raise ArgumentError,
        message:
          "#{inspect(workflow_module)} must define __workflow_config__/0 (use Cyclium.Workflow)"
    end

    config = workflow_module.__workflow_config__()

    unless config.trigger do
      raise ArgumentError, message: "#{inspect(workflow_module)} must declare a trigger"
    end

    validate_workflow_trigger!(workflow_module, config.trigger)

    unless map_size(config.steps) > 0 do
      raise ArgumentError, message: "#{inspect(workflow_module)} must define at least one step"
    end

    Enum.each(config.steps, fn {step_id, step} ->
      unless step.actor do
        raise ArgumentError, message: "Step #{inspect(step_id)}: must declare an actor"
      end

      unless step.expectation do
        raise ArgumentError, message: "Step #{inspect(step_id)}: must declare an expectation"
      end

      unless is_atom(step.expectation) do
        raise ArgumentError,
          message: "Step #{inspect(step_id)}: expectation must be an atom"
      end
    end)

    adj = Map.new(config.steps, fn {id, step} -> {id, step.depends_on} end)
    :ok = Cyclium.Workflow.DAG.validate!(adj)

    step_ids = MapSet.new(Map.keys(config.steps))

    Enum.each(config.steps, fn {step_id, step} ->
      Enum.each(step.depends_on, fn dep ->
        unless MapSet.member?(step_ids, dep) do
          raise ArgumentError,
            message: "Step #{inspect(step_id)} depends_on unknown step #{inspect(dep)}"
        end
      end)
    end)

    :ok
  end

  @doc false
  def validate_failure_policies!(workflow_module) do
    config = workflow_module.__workflow_config__()
    step_ids = MapSet.new(Map.keys(config.steps))

    Enum.each(config.failure_policies, fn {step_id, policy} ->
      unless MapSet.member?(step_ids, step_id) do
        raise ArgumentError,
          message: "Failure policy references unknown step #{inspect(step_id)}"
      end

      unless policy.policy in [:abort, :retry, :continue] do
        raise ArgumentError,
          message: "Step #{inspect(step_id)}: invalid failure policy #{inspect(policy.policy)}"
      end

      if policy.policy == :retry do
        if max = Map.get(policy, :max_step_attempts) do
          unless is_integer(max) and max > 0 do
            raise ArgumentError,
              message: "Step #{inspect(step_id)}: max_step_attempts must be positive"
          end
        end

        if backoff = Map.get(policy, :backoff_ms) do
          unless is_integer(backoff) and backoff >= 0 do
            raise ArgumentError,
              message: "Step #{inspect(step_id)}: backoff_ms must be non-negative"
          end
        end
      end
    end)
  end

  @doc false
  def validate_failure_policies_complete!(workflow_module) do
    config = workflow_module.__workflow_config__()

    Enum.each(config.steps, fn {step_id, _step} ->
      unless Map.has_key?(config.failure_policies, step_id) do
        raise ArgumentError,
          message: "Step #{inspect(step_id)} has no failure policy defined"
      end
    end)
  end

  @doc false
  def validate_step_inputs!(workflow_module, opts) do
    trigger = Keyword.fetch!(opts, :trigger)
    config = workflow_module.__workflow_config__()

    default_prior =
      Map.new(config.steps, fn {step_id, _} -> {step_id, %{"status" => "done"}} end)

    prior = Keyword.get(opts, :prior, default_prior)

    if function_exported?(workflow_module, :__workflow_step_input__, 3) do
      Enum.each(config.steps, fn {step_id, _step} ->
        try do
          result = workflow_module.__workflow_step_input__(step_id, trigger, prior)

          unless is_map(result) do
            raise ArgumentError,
              message:
                "Step #{inspect(step_id)} input function must return a map, got: #{inspect(result)}"
          end
        rescue
          e in ArgumentError ->
            reraise e, __STACKTRACE__

          e ->
            raise ArgumentError,
              message: "Step #{inspect(step_id)} input function crashed: #{Exception.message(e)}"
        end
      end)
    end
  end

  @doc false
  def validate_workflow_trigger!(workflow_module, trigger) do
    case trigger do
      {:event, type} when is_binary(type) ->
        :ok

      {:schedule, ms} when is_integer(ms) and ms > 0 ->
        :ok

      other ->
        raise ArgumentError,
          message: "#{inspect(workflow_module)} has invalid trigger: #{inspect(other)}"
    end
  end
end

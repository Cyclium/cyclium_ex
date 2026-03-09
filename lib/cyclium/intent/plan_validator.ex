defmodule Cyclium.Intent.PlanValidator do
  @moduledoc """
  Structural validation for ActionPlans. Runtime-owned checks only.
  """

  alias Cyclium.Intent.ActionPlan

  @max_plan_steps_default 10

  @spec validate(ActionPlan.t(), keyword()) :: :ok | {:error, binary()}
  def validate(%ActionPlan{} = plan, opts \\ []) do
    max_steps = Keyword.get(opts, :max_plan_steps, @max_plan_steps_default)

    with :ok <- validate_kind(plan),
         :ok <- validate_risk(plan),
         :ok <- validate_fields(plan, max_steps) do
      :ok
    end
  end

  defp validate_kind(%{kind: kind})
       when kind in [
              :tool_call,
              :multi_tool_plan,
              :output_proposal,
              :explain_only,
              :request_approval,
              :workflow_trigger
            ],
       do: :ok

  defp validate_kind(%{kind: kind}), do: {:error, "unknown plan kind: #{inspect(kind)}"}

  defp validate_risk(%{risk: risk}) when risk in [:low, :medium, :high], do: :ok
  defp validate_risk(%{risk: risk}), do: {:error, "unknown risk level: #{inspect(risk)}"}

  defp validate_fields(%{kind: :tool_call, tool: nil}, _),
    do: {:error, ":tool_call requires tool field"}

  defp validate_fields(%{kind: :tool_call}, _), do: :ok

  defp validate_fields(%{kind: :multi_tool_plan, steps: steps}, max_steps) do
    cond do
      steps == [] ->
        {:error, ":multi_tool_plan requires at least 1 step"}

      length(steps) > max_steps ->
        {:error, ":multi_tool_plan exceeds max_plan_steps (#{max_steps})"}

      true ->
        :ok
    end
  end

  defp validate_fields(%{kind: :output_proposal, output: nil}, _),
    do: {:error, ":output_proposal requires output field"}

  defp validate_fields(%{kind: :output_proposal}, _), do: :ok

  defp validate_fields(%{kind: :explain_only}, _), do: :ok

  defp validate_fields(%{kind: :request_approval, approval: nil}, _),
    do: {:error, ":request_approval requires approval field"}

  defp validate_fields(%{kind: :request_approval}, _), do: :ok

  defp validate_fields(%{kind: :workflow_trigger, workflow: nil}, _),
    do: {:error, ":workflow_trigger requires workflow field"}

  defp validate_fields(%{kind: :workflow_trigger, workflow: wf}, _) do
    if wf.workflow_id do
      :ok
    else
      {:error, ":workflow_trigger requires workflow_id"}
    end
  end

  defp validate_fields(_, _), do: :ok
end

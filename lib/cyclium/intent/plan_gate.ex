defmodule Cyclium.Intent.PlanGate do
  @moduledoc """
  Orchestrates structural validation, signature matching, constraint checks,
  and app policy callbacks for an action plan.
  """

  alias Cyclium.Intent.{
    ActionPlan,
    PlanValidator,
    SignatureMatcher,
    ConstraintChecks,
    ToolSignature
  }

  @spec evaluate(ActionPlan.t(), map(), map()) :: :ok | {:deny, binary()}
  def evaluate(%ActionPlan{} = plan, ctx, strategy_cfg) do
    signatures = parse_signatures(strategy_cfg)
    max_steps = strategy_cfg["max_plan_steps"] || 10
    policy_mod = strategy_cfg["plan_policy"]

    with :ok <- PlanValidator.validate(plan, max_plan_steps: max_steps),
         :ok <- check_signatures(plan, signatures, ctx, policy_mod),
         :ok <- check_output(plan, ctx, policy_mod),
         :ok <- check_app_policy(plan, ctx, strategy_cfg, policy_mod) do
      :ok
    end
  end

  defp check_signatures(%{kind: :tool_call, tool: tool}, signatures, ctx, policy_mod) do
    check_single_tool(tool, signatures, ctx, policy_mod)
  end

  defp check_signatures(%{kind: :multi_tool_plan, steps: steps}, signatures, ctx, policy_mod) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case check_single_tool(step, signatures, ctx, policy_mod) do
        :ok -> {:cont, :ok}
        deny -> {:halt, deny}
      end
    end)
  end

  defp check_signatures(_plan, _sigs, _ctx, _policy), do: :ok

  defp check_single_tool(step, signatures, ctx, policy_mod) do
    with {:ok, sig} <- SignatureMatcher.match(step, signatures),
         :ok <- ConstraintChecks.check(step.args, sig),
         :ok <- maybe_validate_tool_args(policy_mod, ctx, step.tool, step.args, sig) do
      :ok
    else
      {:error, :no_matching_signature} ->
        {:deny, "tool #{inspect(step.tool)} not in allowed signatures"}

      {:deny, _} = deny ->
        deny
    end
  end

  defp check_output(%{kind: :output_proposal, output: output}, ctx, policy_mod)
       when not is_nil(output) and not is_nil(policy_mod) do
    mod = resolve_module(policy_mod)
    if mod, do: mod.validate_output(ctx, output), else: :ok
  end

  defp check_output(_plan, _ctx, _policy), do: :ok

  defp check_app_policy(_plan, _ctx, _cfg, nil), do: :ok

  defp check_app_policy(plan, ctx, strategy_cfg, policy_mod) do
    case resolve_module(policy_mod) do
      nil -> :ok
      mod -> mod.validate_plan(ctx, plan, strategy_cfg)
    end
  end

  defp maybe_validate_tool_args(nil, _ctx, _tool, _args, _sig), do: :ok

  defp maybe_validate_tool_args(policy_mod, ctx, tool, args, sig) do
    case resolve_module(policy_mod) do
      nil -> :ok
      mod -> mod.validate_tool_args(ctx, tool, args, sig)
    end
  end

  defp parse_signatures(%{"allowed_tool_signatures" => sigs}) when is_list(sigs) do
    Enum.map(sigs, fn sig ->
      %ToolSignature{
        name: sig["name"],
        version: sig["version"] || 1,
        side_effect: parse_side_effect(sig["side_effect"]),
        args_schema: sig["args_schema"],
        constraints: sig["constraints"] || %{}
      }
    end)
  end

  defp parse_signatures(_), do: []

  defp parse_side_effect("read"), do: :read
  defp parse_side_effect("write"), do: :write
  defp parse_side_effect("external_effect"), do: :external_effect
  defp parse_side_effect(atom) when is_atom(atom), do: atom
  defp parse_side_effect(_), do: :read

  defp resolve_module(mod) when is_atom(mod) and not is_nil(mod), do: mod

  defp resolve_module(mod) when is_binary(mod) do
    try do
      String.to_existing_atom("Elixir.#{mod}")
    rescue
      ArgumentError -> nil
    end
  end

  defp resolve_module(_), do: nil
end

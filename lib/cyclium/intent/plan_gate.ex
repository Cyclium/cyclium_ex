defmodule Cyclium.Intent.PlanGate do
  @moduledoc """
  The gate every model-authored plan passes before anything runs. Orchestrates
  structural validation, tool-signature and action matching, constraint checks,
  output-type and workflow allow-lists, and the app's optional `plan_policy`
  callbacks.

  Everything here is deny-by-default:

    * a tool call must name an allowed tool **and** an allowed action;
    * an output proposal must use a type in `allowed_output_types`;
    * a workflow trigger must name a workflow in `allowed_workflows`;
    * a `plan_policy`, when set, must be a loaded `Cyclium.Intent.PlanPolicy`
      module; one that is not, or that raises, denies the plan rather than
      failing open or crashing the episode.

  No policy is needed for an actor to be bounded; the allow-lists do that. A
  policy adds per-principal rules the static lists cannot express, and is a
  module set in the expectation's `strategy_config`
  (`strategy_config: %{plan_policy: MyApp.Policy, ...}`). A string is never
  resolved to a module, so DB-defined config cannot name one.
  """

  require Logger

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

    with {:ok, policy_mod} <- resolve_policy(strategy_cfg["plan_policy"]),
         :ok <- validate_structure(plan, max_steps),
         :ok <- check_signatures(plan, signatures, ctx, policy_mod),
         :ok <- check_output_type(plan, strategy_cfg),
         :ok <- check_output(plan, ctx, policy_mod),
         :ok <- check_workflow(plan, strategy_cfg),
         :ok <- check_app_policy(plan, ctx, strategy_cfg, policy_mod) do
      :ok
    end
  end

  @doc """
  Parse `allowed_tool_signatures` from a strategy config into signature structs.
  Shared with the agentic loop so the gate and the preview decision see the same
  signatures.
  """
  @spec parse_signatures(map()) :: [ToolSignature.t()]
  def parse_signatures(%{"allowed_tool_signatures" => sigs}) when is_list(sigs) do
    Enum.map(sigs, &ToolSignature.from_config/1)
  end

  def parse_signatures(_), do: []

  # PlanValidator reports `{:error, msg}`; the gate's contract is `{:deny, msg}`.
  # Returning the validator's shape unchanged used to escape as a CaseClauseError
  # in the strategy's :validate phase.
  defp validate_structure(plan, max_steps) do
    case PlanValidator.validate(plan, max_plan_steps: max_steps) do
      :ok -> :ok
      {:error, msg} -> {:deny, "invalid plan: #{msg}"}
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

      {:error, :action_not_allowed} ->
        {:deny,
         "action #{inspect(step.action)} of tool #{inspect(step.tool)} not in allowed signatures"}

      {:deny, _} = deny ->
        deny
    end
  end

  # An output proposal may only use a type the strategy lists. The list is also
  # what the prompt advertises; an absent or empty list allows no outputs.
  defp check_output_type(%{kind: :output_proposal, output: %{type: type}}, strategy_cfg) do
    allowed = allow_list(strategy_cfg, "allowed_output_types")

    if to_string(type) in allowed do
      :ok
    else
      {:deny, "output type #{inspect(to_string(type))} not in allowed_output_types"}
    end
  end

  defp check_output_type(_plan, _cfg), do: :ok

  defp check_output(%{kind: :output_proposal, output: output}, ctx, policy_mod)
       when not is_nil(output) and not is_nil(policy_mod) do
    call_policy(policy_mod, :validate_output, [ctx, output])
  end

  defp check_output(_plan, _ctx, _policy), do: :ok

  # A workflow trigger may only start a workflow the strategy lists; the model
  # chooses the id and the input, so the id must come from an allow-list.
  defp check_workflow(%{kind: :workflow_trigger, workflow: %{workflow_id: id}}, strategy_cfg) do
    allowed = allow_list(strategy_cfg, "allowed_workflows")

    if to_string(id) in allowed do
      :ok
    else
      {:deny, "workflow #{inspect(to_string(id))} not in allowed_workflows"}
    end
  end

  defp check_workflow(_plan, _cfg), do: :ok

  defp allow_list(strategy_cfg, key) do
    (strategy_cfg[key] || strategy_cfg[String.to_atom(key)] || [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp check_app_policy(_plan, _ctx, _cfg, nil), do: :ok

  defp check_app_policy(plan, ctx, strategy_cfg, policy_mod) do
    call_policy(policy_mod, :validate_plan, [ctx, plan, strategy_cfg])
  end

  defp maybe_validate_tool_args(nil, _ctx, _tool, _args, _sig), do: :ok

  defp maybe_validate_tool_args(policy_mod, ctx, tool, args, sig) do
    call_policy(policy_mod, :validate_tool_args, [ctx, tool, args, sig])
  end

  # A policy that raises, or returns something other than :ok / {:deny, _},
  # denies the plan. Failing open here would turn a policy bug into a bypass;
  # crashing would fail the episode with no user-facing reason.
  defp call_policy(mod, fun, args) do
    case apply(mod, fun, args) do
      :ok ->
        :ok

      {:deny, reason} = deny when is_binary(reason) ->
        deny

      other ->
        Logger.warning(
          "[Cyclium.Intent.PlanGate] #{inspect(mod)}.#{fun} returned #{inspect(other)}; denying plan"
        )

        {:deny, "plan policy returned an unexpected result"}
    end
  rescue
    e ->
      Logger.warning(
        "[Cyclium.Intent.PlanGate] #{inspect(mod)}.#{fun} raised #{Exception.message(e)}; denying plan"
      )

      {:deny, "plan policy failed"}
  end

  # --- policy resolution ---

  @policy_callbacks [validate_plan: 3, validate_tool_args: 4, validate_output: 2]

  @doc false
  @spec resolve_policy(term()) :: {:ok, module() | nil} | {:deny, binary()}
  def resolve_policy(nil), do: {:ok, nil}

  def resolve_policy(mod) when is_atom(mod) do
    if policy_module?(mod) do
      {:ok, mod}
    else
      {:deny, "plan_policy #{inspect(mod)} is not a loaded Cyclium.Intent.PlanPolicy module"}
    end
  end

  def resolve_policy(other) do
    {:deny,
     "plan_policy must be a module set on the expectation's strategy_config, got #{inspect(other)}"}
  end

  defp policy_module?(mod) do
    Code.ensure_loaded?(mod) and
      Enum.all?(@policy_callbacks, fn {fun, arity} -> function_exported?(mod, fun, arity) end)
  end
end

defmodule Cyclium.Intent.PlanGatePolicyTest do
  @moduledoc """
  Tests PlanGate integration with app-owned PlanPolicy callbacks.
  """
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{ActionPlan, PlanGate, ToolCallStep}

  # A test policy module that denies plans with high risk
  defmodule TestPolicy do
    @behaviour Cyclium.Intent.PlanPolicy

    @impl true
    def validate_plan(_ctx, %{risk: :high}, _cfg), do: {:deny, "high risk plans not allowed"}
    def validate_plan(_ctx, _plan, _cfg), do: :ok

    @impl true
    def validate_tool_args(_ctx, "dangerous_tool", _args, _sig),
      do: {:deny, "dangerous_tool is banned"}

    def validate_tool_args(_ctx, _tool, _args, _sig), do: :ok

    @impl true
    def validate_output(_ctx, %{type: :sms}), do: {:deny, "SMS outputs not allowed"}
    def validate_output(_ctx, _output), do: :ok
  end

  defp plan(overrides) do
    defaults = %{kind: :explain_only, risk: :low, why: "test"}
    struct!(ActionPlan, Map.merge(defaults, overrides))
  end

  defp step(tool, args \\ %{}) do
    %ToolCallStep{tool: tool, action: "go", args: args}
  end

  defp strategy_cfg(policy_mod) do
    cfg = %{
      "allowed_tool_signatures" => [
        %{"name" => "lookup_user", "side_effect" => "read"},
        %{"name" => "dangerous_tool", "side_effect" => "write"}
      ]
    }

    if policy_mod, do: Map.put(cfg, "plan_policy", policy_mod), else: cfg
  end

  describe "app policy callbacks" do
    test "validate_plan denies high-risk plans" do
      p = plan(%{risk: :high})

      assert {:deny, "high risk plans not allowed"} =
               PlanGate.evaluate(p, %{}, strategy_cfg(TestPolicy))
    end

    test "validate_plan allows low-risk plans" do
      p = plan(%{risk: :low})
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg(TestPolicy))
    end

    test "validate_tool_args denies banned tools" do
      p = plan(%{kind: :tool_call, tool: step("dangerous_tool")})

      assert {:deny, "dangerous_tool is banned"} =
               PlanGate.evaluate(p, %{}, strategy_cfg(TestPolicy))
    end

    test "validate_tool_args passes for allowed tools" do
      p = plan(%{kind: :tool_call, tool: step("lookup_user")})
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg(TestPolicy))
    end

    test "validate_output denies SMS outputs" do
      output = %Cyclium.OutputProposal{
        type: :sms,
        dedupe_key: "dk1",
        payload: %{},
        requires_approval: false
      }

      p = plan(%{kind: :output_proposal, output: output})

      assert {:deny, "SMS outputs not allowed"} =
               PlanGate.evaluate(p, %{}, strategy_cfg(TestPolicy))
    end

    test "no policy module means no policy checks" do
      p = plan(%{risk: :high})
      # Without policy, high risk is still structurally valid
      assert :ok = PlanGate.evaluate(p, %{}, strategy_cfg(nil))
    end

    test "policy module as string" do
      p = plan(%{risk: :high})
      mod_string = to_string(TestPolicy)
      # Remove "Elixir." prefix that to_string adds
      mod_string = String.replace_prefix(mod_string, "Elixir.", "")

      assert {:deny, "high risk plans not allowed"} =
               PlanGate.evaluate(p, %{}, strategy_cfg(mod_string))
    end
  end
end

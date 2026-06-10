defmodule Cyclium.Conversations.DispatchTest do
  # Not async: resolve_interactive_expectation/1 reads the global persistent_term
  # table, which these tests mutate.
  use ExUnit.Case, async: false

  alias Cyclium.Conversations.Dispatch
  alias Cyclium.Strategy.Template.Interactive

  # Register an expectation strategy + budget + log_strategy in persistent_term,
  # mirroring what the Actor DSL does at boot. Cleaned up after each test.
  defp register(actor, exp, strategy, budget \\ %{"max_turns" => 7}, log \\ :timeline) do
    :persistent_term.put({:cyclium_actor_strategy, actor, exp}, strategy)
    :persistent_term.put({:cyclium_expectation_budget, actor, exp}, budget)
    :persistent_term.put({:cyclium_expectation_log_strategy, actor, exp}, log)

    on_exit(fn ->
      :persistent_term.erase({:cyclium_actor_strategy, actor, exp})
      :persistent_term.erase({:cyclium_expectation_budget, actor, exp})
      :persistent_term.erase({:cyclium_expectation_log_strategy, actor, exp})
    end)
  end

  describe "resolve_interactive_expectation/1" do
    test "returns the single interactive expectation with its budget and log strategy" do
      register(:disp_test_actor_one, :only_conv, Interactive, %{"max_turns" => 9}, :full_debug)

      assert {:ok, :only_conv, %{"max_turns" => 9}, :full_debug} =
               Dispatch.resolve_interactive_expectation(:disp_test_actor_one)
    end

    test "errors when the actor has no interactive expectation" do
      register(:disp_test_actor_none, :some_conv, SomeOtherStrategy)

      assert {:error, :no_interactive_expectation} =
               Dispatch.resolve_interactive_expectation(:disp_test_actor_none)
    end

    test "errors deterministically when two interactive expectations exist" do
      register(:disp_test_actor_two, :conv_b, Interactive)
      register(:disp_test_actor_two, :conv_a, Interactive)

      assert {:error, {:ambiguous_interactive_expectation, ids}} =
               Dispatch.resolve_interactive_expectation(:disp_test_actor_two)

      # Sorted, so the order is stable regardless of persistent_term iteration order.
      assert ids == [:conv_a, :conv_b]
    end
  end
end

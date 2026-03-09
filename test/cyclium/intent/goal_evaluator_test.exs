defmodule Cyclium.Intent.GoalEvaluatorTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.GoalEvaluator
  alias Cyclium.Intent.GoalSpec
  alias Cyclium.ConvergeResult

  defp goal(overrides) do
    struct!(GoalSpec, Map.merge(%{type: "assist"}, overrides))
  end

  defp result(overrides) do
    struct!(ConvergeResult, overrides)
  end

  describe "StrategyDecides mode" do
    test "continues when no resolution signal" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})
      r = result(%{classification: %{"something" => true}})

      assert :continue = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "resolves on conversation_resolved signal (string keys)" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})

      r =
        result(%{
          classification: %{
            "conversation_resolved" => true,
            "outcome" => "completed",
            "result" => %{"data" => "yes"}
          }
        })

      assert {:resolved, "completed", %{"data" => "yes"}} = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "resolves with empty result when result key missing" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})

      r =
        result(%{
          classification: %{"conversation_resolved" => true, "outcome" => "done"}
        })

      assert {:resolved, "done", %{}} = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "abandons on conversation_abandoned signal" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})

      r =
        result(%{
          classification: %{"conversation_abandoned" => true, "reason" => "user gave up"}
        })

      assert {:abandoned, "user gave up"} = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "resolves with atom keys" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})

      r =
        result(%{
          classification: %{conversation_resolved: true, outcome: :done, result: %{x: 1}}
        })

      assert {:resolved, "done", %{x: 1}} = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "continues when classification is nil" do
      g = goal(%{completion_criteria: %{mode: :strategy_decides}})
      r = result(%{classification: nil})

      assert :continue = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "defaults to strategy_decides for unknown mode" do
      g = goal(%{completion_criteria: %{}})
      r = result(%{classification: %{"conversation_resolved" => true, "outcome" => "ok"}})

      assert {:resolved, "ok", %{}} = GoalEvaluator.evaluate(g, %{}, r)
    end

    test "works with string-keyed completion_criteria" do
      g = goal(%{completion_criteria: %{"mode" => "strategy_decides"}})
      r = result(%{classification: %{"conversation_resolved" => true, "outcome" => "ok"}})

      assert {:resolved, "ok", %{}} = GoalEvaluator.evaluate(g, %{}, r)
    end
  end

  describe "RequiredFields mode" do
    test "continues when required fields not yet collected" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "name", required: true, type: :any},
              %{key: "email", required: true, type: :any}
            ]
          }
        })

      state = %{collected_fields: %{"name" => "Alice"}}
      r = result(%{classification: %{}})

      assert :continue = GoalEvaluator.evaluate(g, state, r)
    end

    test "resolves when all required fields collected" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "name", required: true, type: :any},
              %{key: "email", required: true, type: :any}
            ]
          }
        })

      state = %{collected_fields: %{"name" => "Alice"}}
      r = result(%{classification: %{"collected_fields" => %{"email" => "a@b.com"}}})

      assert {:resolved, "completed", collected} = GoalEvaluator.evaluate(g, state, r)
      assert collected["name"] == "Alice"
      assert collected["email"] == "a@b.com"
    end

    test "list type requires min count" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "items", required: true, type: :list, min: 2}
            ]
          }
        })

      state = %{collected_fields: %{"items" => ["one"]}}
      r = result(%{classification: %{}})

      assert :continue = GoalEvaluator.evaluate(g, state, r)
    end

    test "list type resolves when min count met" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "items", required: true, type: :list, min: 2}
            ]
          }
        })

      state = %{collected_fields: %{"items" => ["one", "two"]}}
      r = result(%{classification: %{}})

      assert {:resolved, "completed", _} = GoalEvaluator.evaluate(g, state, r)
    end

    test "boolean type requires true" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "confirmed", required: true, type: :boolean}
            ]
          }
        })

      state = %{collected_fields: %{"confirmed" => false}}
      r = result(%{classification: %{}})

      assert :continue = GoalEvaluator.evaluate(g, state, r)
    end

    test "optional fields don't block resolution" do
      g =
        goal(%{
          completion_criteria: %{
            mode: :required_fields,
            fields: [
              %{key: "name", required: true, type: :any},
              %{key: "nickname", required: false, type: :any}
            ]
          }
        })

      state = %{collected_fields: %{"name" => "Alice"}}
      r = result(%{classification: %{}})

      assert {:resolved, "completed", _} = GoalEvaluator.evaluate(g, state, r)
    end

    test "works with string-keyed criteria" do
      g =
        goal(%{
          completion_criteria: %{
            "mode" => "required_fields",
            "fields" => [
              %{"key" => "name", "required" => true, "type" => "any"}
            ]
          }
        })

      state = %{collected_fields: %{"name" => "Bob"}}
      r = result(%{classification: %{}})

      assert {:resolved, "completed", _} = GoalEvaluator.evaluate(g, state, r)
    end
  end
end

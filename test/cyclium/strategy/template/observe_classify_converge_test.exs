defmodule Cyclium.Strategy.Template.ObserveClassifyConvergeTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.ObserveClassifyConverge

  # Test the rule classification logic directly via the strategy callbacks
  # (These tests don't need a DB — they test the pure logic)

  describe "classification rules" do
    test "first matching rule wins" do
      state = %{
        phase: :gather,
        strategy_config: %{
          "gatherer" => "test",
          "classify_rules" => [
            %{
              "field" => "score",
              "op" => "lt",
              "value" => 50,
              "class" => "low",
              "severity" => "high"
            },
            %{
              "field" => "score",
              "op" => "lt",
              "value" => 80,
              "class" => "medium",
              "severity" => "medium"
            }
          ],
          "default_class" => "good",
          "default_severity" => "low",
          "finding_config" => %{}
        },
        trigger_payload: %{},
        gathered_data: nil,
        classification: nil
      }

      # Score 30 matches first rule
      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"score" => 30}})
      assert result.classification == %{"class" => "low", "severity" => "high"}

      # Score 60 matches second rule
      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"score" => 60}})
      assert result.classification == %{"class" => "medium", "severity" => "medium"}

      # Score 90 matches no rules, uses defaults
      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"score" => 90}})
      assert result.classification == %{"class" => "good", "severity" => "low"}
    end

    test "lt operator" do
      state =
        base_state([
          %{"field" => "val", "op" => "lt", "value" => 10, "class" => "low", "severity" => "high"}
        ])

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"val" => 5}})
      assert result.classification["class"] == "low"

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"val" => 15}})
      assert result.classification["class"] == "default"
    end

    test "gt operator" do
      state =
        base_state([
          %{
            "field" => "val",
            "op" => "gt",
            "value" => 10,
            "class" => "high",
            "severity" => "high"
          }
        ])

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"val" => 15}})
      assert result.classification["class"] == "high"

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"val" => 5}})
      assert result.classification["class"] == "default"
    end

    test "eq operator" do
      state =
        base_state([
          %{
            "field" => "status",
            "op" => "eq",
            "value" => "active",
            "class" => "active",
            "severity" => "low"
          }
        ])

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"status" => "active"}})

      assert result.classification["class"] == "active"

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"status" => "inactive"}})

      assert result.classification["class"] == "default"
    end

    test "neq operator" do
      state =
        base_state([
          %{
            "field" => "status",
            "op" => "neq",
            "value" => "ok",
            "class" => "problem",
            "severity" => "medium"
          }
        ])

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"status" => "error"}})

      assert result.classification["class"] == "problem"

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"status" => "ok"}})

      assert result.classification["class"] == "default"
    end

    test "in operator" do
      state =
        base_state([
          %{
            "field" => "tier",
            "op" => "in",
            "value" => ["gold", "platinum"],
            "class" => "premium",
            "severity" => "low"
          }
        ])

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"tier" => "gold"}})

      assert result.classification["class"] == "premium"

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"tier" => "bronze"}})

      assert result.classification["class"] == "default"
    end

    test "not_in operator" do
      state =
        base_state([
          %{
            "field" => "tier",
            "op" => "not_in",
            "value" => ["gold", "platinum"],
            "class" => "standard",
            "severity" => "low"
          }
        ])

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"tier" => "bronze"}})

      assert result.classification["class"] == "standard"

      {:ok, result} =
        ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"tier" => "gold"}})

      assert result.classification["class"] == "default"
    end

    test "empty rules use defaults" do
      state = base_state([])

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{"val" => 42}})
      assert result.classification == %{"class" => "default", "severity" => "low"}
    end

    test "atom keys in data are normalized to strings" do
      state =
        base_state([
          %{
            "field" => "score",
            "op" => "lt",
            "value" => 50,
            "class" => "low",
            "severity" => "high"
          }
        ])

      {:ok, result} = ObserveClassifyConverge.handle_result(state, %{}, {:ok, %{score: 30}})
      assert result.classification["class"] == "low"
    end
  end

  describe "converge/2" do
    test "produces ConvergeResult with classification" do
      state = %{
        phase: :done,
        strategy_config: %{"finding_config" => %{}},
        trigger_payload: %{},
        gathered_data: %{"score" => 30},
        classification: %{"class" => "low", "severity" => "high"}
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveClassifyConverge.converge(state, episode_ctx)

      assert result.classification == %{"primary" => "low", "severity" => "high"}
      assert result.confidence == 1.0
      assert result.summary =~ "low"
    end

    test "produces findings with finding_config" do
      state = %{
        phase: :done,
        strategy_config: %{
          "finding_config" => %{
            "subject_kind" => "project",
            "subject_id_key" => "project_id",
            "finding_key_template" => "project:risk:${subject_id}"
          }
        },
        trigger_payload: %{"project_id" => "123"},
        gathered_data: %{"score" => 30},
        classification: %{"class" => "at_risk", "severity" => "high"}
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveClassifyConverge.converge(state, episode_ctx)

      assert length(result.findings) == 1
      {:raise, finding} = hd(result.findings)
      assert finding.finding_key == "project:risk:123"
      assert finding.subject_kind == "project"
      assert finding.subject_id == "123"
      assert finding.class == "at_risk"
      assert finding.severity == :high
    end

    test "no findings when gathered data has error" do
      state = %{
        phase: :done,
        strategy_config: %{"finding_config" => %{}},
        trigger_payload: %{},
        gathered_data: %{_error: true, reason: "fail"},
        classification: %{"class" => "error", "severity" => "low"}
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveClassifyConverge.converge(state, episode_ctx)
      assert result.findings == []
    end
  end

  # Helper to build a minimal state for rule tests
  defp base_state(rules) do
    %{
      phase: :gather,
      strategy_config: %{
        "gatherer" => "test",
        "classify_rules" => rules,
        "default_class" => "default",
        "default_severity" => "low",
        "finding_config" => %{}
      },
      trigger_payload: %{},
      gathered_data: nil,
      classification: nil
    }
  end
end

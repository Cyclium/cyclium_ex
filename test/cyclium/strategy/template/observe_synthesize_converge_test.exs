defmodule Cyclium.Strategy.Template.ObserveSynthesizeConvergeTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.ObserveSynthesizeConverge

  describe "handle_result/3 — gather phase" do
    test "transitions from gather to synthesize on success" do
      state = %{
        phase: :gather,
        strategy_config: %{},
        trigger_payload: %{},
        gathered_data: nil,
        synthesis_result: nil
      }

      {:ok, new_state} = ObserveSynthesizeConverge.handle_result(state, %{}, {:ok, %{foo: "bar"}})

      assert new_state.phase == :synthesize
      assert new_state.gathered_data == %{foo: "bar"}
    end

    test "transitions from gather to done on error data" do
      state = %{
        phase: :gather,
        strategy_config: %{},
        trigger_payload: %{},
        gathered_data: nil,
        synthesis_result: nil
      }

      {:ok, new_state} =
        ObserveSynthesizeConverge.handle_result(
          state,
          %{},
          {:ok, %{_error: true, reason: "fail"}}
        )

      assert new_state.phase == :done
      assert new_state.gathered_data[:_error] == true
    end
  end

  describe "handle_result/3 — synthesize phase" do
    test "stores synthesis result and transitions to done" do
      state = %{
        phase: :synthesize,
        strategy_config: %{},
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: nil
      }

      result = %{"class" => "healthy", "severity" => "low", "summary" => "All good"}
      {:ok, new_state} = ObserveSynthesizeConverge.handle_result(state, %{}, {:ok, result})

      assert new_state.phase == :done
      assert new_state.synthesis_result == result
    end

    test "retries on synthesis error" do
      state = %{
        phase: :synthesize,
        strategy_config: %{},
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: nil
      }

      step = %{kind: :synthesis}

      {:retry, new_state} =
        ObserveSynthesizeConverge.handle_result(state, step, {:error, {:llm_error, "timeout"}})

      assert new_state.__retries[:synthesis] == 1
    end

    test "gives up after max retries" do
      state = %{
        phase: :synthesize,
        strategy_config: %{},
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: nil,
        __retries: %{synthesis: 2}
      }

      step = %{kind: :synthesis}

      {:ok, new_state} =
        ObserveSynthesizeConverge.handle_result(state, step, {:error, {:llm_error, "timeout"}})

      assert new_state.phase == :done
      assert new_state.synthesis_result["_error"] == true
      assert new_state.synthesis_result["summary"] =~ "failed after 3 attempts"
    end
  end

  describe "next_step/2 — gather phase with crashing gatherer" do
    setup do
      old_registry = Application.get_env(:cyclium, :gatherer_registry, %{})

      on_exit(fn ->
        Application.put_env(:cyclium, :gatherer_registry, old_registry)
      end)

      :ok
    end

    test "catches exception from gatherer and returns error observation" do
      defmodule CrashingGatherer do
        def gather(_trigger, _config), do: raise("boom!")
      end

      Application.put_env(:cyclium, :gatherer_registry, %{
        "crashing" => CrashingGatherer
      })

      state = %{
        phase: :gather,
        strategy_config: %{"gatherer" => "crashing"},
        trigger_payload: %{},
        gathered_data: nil,
        synthesis_result: nil
      }

      assert {:observe, data} = ObserveSynthesizeConverge.next_step(state, %{})
      assert data[:_error] == true
      assert data[:reason] =~ "error"
    end

    test "catches throw from gatherer" do
      defmodule ThrowingGatherer do
        def gather(_trigger, _config), do: throw(:oops)
      end

      Application.put_env(:cyclium, :gatherer_registry, %{
        "throwing" => ThrowingGatherer
      })

      state = %{
        phase: :gather,
        strategy_config: %{"gatherer" => "throwing"},
        trigger_payload: %{},
        gathered_data: nil,
        synthesis_result: nil
      }

      assert {:observe, data} = ObserveSynthesizeConverge.next_step(state, %{})
      assert data[:_error] == true
    end
  end

  describe "converge/2" do
    test "produces findings from synthesis result" do
      state = %{
        phase: :done,
        strategy_config: %{
          "finding_config" => %{
            "actor_id_field" => "my_actor",
            "finding_key_template" => "test:${subject_id}",
            "class_field" => "class",
            "severity_field" => "severity",
            "summary_field" => "summary",
            "subject_kind" => "project",
            "subject_id_key" => "project_id"
          }
        },
        trigger_payload: %{"project_id" => "123"},
        gathered_data: %{},
        synthesis_result: %{
          "class" => "at_risk",
          "severity" => "high",
          "summary" => "Project needs attention",
          "confidence" => 0.9
        }
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveSynthesizeConverge.converge(state, episode_ctx)

      assert result.classification == %{"primary" => "at_risk", "severity" => "high"}
      assert result.confidence == 0.9
      assert result.summary == "Project needs attention"

      assert length(result.findings) == 1
      {:raise, finding} = hd(result.findings)
      assert finding.finding_key == "test:123"
      assert finding.class == "at_risk"
      assert finding.severity == :high
      assert finding.subject_kind == "project"
      assert finding.subject_id == "123"
    end

    test "no findings when synthesis failed" do
      state = %{
        phase: :done,
        strategy_config: %{"finding_config" => %{}},
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: %{"_error" => true, "summary" => "LLM failed"}
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveSynthesizeConverge.converge(state, episode_ctx)
      assert result.findings == []
    end

    test "no findings when no synthesis result" do
      state = %{
        phase: :done,
        strategy_config: %{"finding_config" => %{}},
        trigger_payload: %{},
        gathered_data: nil,
        synthesis_result: nil
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveSynthesizeConverge.converge(state, episode_ctx)
      assert result.findings == []
      assert result.summary == "No synthesis result"
    end

    test "builds outputs from config" do
      state = %{
        phase: :done,
        strategy_config: %{
          "finding_config" => %{},
          "outputs" => ["email", "slack"]
        },
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: %{"class" => "ok", "summary" => "fine"}
      }

      episode_ctx = %{episode_id: "ep-1", actor_id: "test_actor", expectation_id: "test_exp"}

      {:ok, result} = ObserveSynthesizeConverge.converge(state, episode_ctx)

      assert length(result.outputs) == 2
      types = Enum.map(result.outputs, & &1.type)
      assert :email in types
      assert :slack in types
    end

    test "finding_key_template substitution" do
      state = %{
        phase: :done,
        strategy_config: %{
          "finding_config" => %{
            "finding_key_template" => "${actor_id}:${subject_id}:${episode_id}"
          }
        },
        trigger_payload: %{},
        gathered_data: %{},
        synthesis_result: %{"class" => "ok", "summary" => "fine"}
      }

      episode_ctx = %{episode_id: "ep-42", actor_id: "my_actor", expectation_id: "my_exp"}

      {:ok, result} = ObserveSynthesizeConverge.converge(state, episode_ctx)

      assert length(result.findings) == 1
      {:raise, finding} = hd(result.findings)
      assert finding.finding_key == "my_actor:ep-42:ep-42"
    end
  end
end

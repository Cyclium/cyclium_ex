defmodule Cyclium.Strategy.Template.DispatchTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.Template.Dispatch

  describe "handle_result/3 — gather phase" do
    test "transitions from gather to dispatch with entities" do
      state = %{
        phase: :gather,
        strategy_config: %{
          "event_type" => "test.event",
          "entity_id_field" => "id",
          "entity_payload_fields" => ["id", "name"]
        },
        trigger_payload: %{},
        entities: [],
        dispatched: 0
      }

      entities = [%{"id" => 1, "name" => "A"}, %{"id" => 2, "name" => "B"}]

      {:ok, new_state} = Dispatch.handle_result(state, %{}, {:ok, %{entities: entities}})

      assert new_state.phase == :dispatch
      assert length(new_state.entities) == 2
    end

    test "transitions to dispatch with empty list" do
      state = %{
        phase: :gather,
        strategy_config: %{},
        trigger_payload: %{},
        entities: [],
        dispatched: 0
      }

      {:ok, new_state} = Dispatch.handle_result(state, %{}, {:ok, %{entities: []}})

      assert new_state.phase == :dispatch
      assert new_state.entities == []
    end
  end

  describe "handle_result/3 — dispatch phase" do
    test "increments dispatched count and removes entity from list" do
      state = %{
        phase: :dispatch,
        strategy_config: %{
          "event_type" => "test.event",
          "entity_id_field" => "id"
        },
        trigger_payload: %{},
        entities: [%{"id" => 1}, %{"id" => 2}],
        dispatched: 0
      }

      # Simulate the dispatch of entity with id=1
      {:ok, new_state} =
        Dispatch.handle_result(state, %{}, {:ok, %{entity: %{"id" => 1}}})

      assert new_state.dispatched == 1
      assert length(new_state.entities) == 1
      assert hd(new_state.entities) == %{"id" => 2}
    end

    test "processes all entities sequentially" do
      state = %{
        phase: :dispatch,
        strategy_config: %{
          "event_type" => "test.event",
          "entity_id_field" => "id"
        },
        trigger_payload: %{},
        entities: [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}],
        dispatched: 0
      }

      {:ok, state} = Dispatch.handle_result(state, %{}, {:ok, %{entity: %{"id" => 1}}})
      assert state.dispatched == 1
      assert length(state.entities) == 2

      {:ok, state} = Dispatch.handle_result(state, %{}, {:ok, %{entity: %{"id" => 2}}})
      assert state.dispatched == 2
      assert length(state.entities) == 1

      {:ok, state} = Dispatch.handle_result(state, %{}, {:ok, %{entity: %{"id" => 3}}})
      assert state.dispatched == 3
      assert state.entities == []
    end
  end

  describe "next_step/2 — dispatch phase" do
    test "returns converge when entities are empty" do
      state = %{
        phase: :dispatch,
        strategy_config: %{},
        entities: [],
        dispatched: 3
      }

      assert Dispatch.next_step(state, %{}) == :converge
    end

    test "returns observe with dispatch action when entities remain" do
      state = %{
        phase: :dispatch,
        strategy_config: %{
          "entity_payload_fields" => ["id", "name"]
        },
        entities: [%{"id" => 1, "name" => "A", "extra" => "ignored"}],
        dispatched: 0
      }

      assert {:observe, data} = Dispatch.next_step(state, %{})
      assert data.action == "dispatch"
      # payload_fields filter applies
      assert Map.has_key?(data.entity, "id")
      assert Map.has_key?(data.entity, "name")
    end
  end

  describe "converge/2" do
    test "produces ConvergeResult with dispatch count" do
      state = %{
        phase: :done,
        strategy_config: %{},
        trigger_payload: %{},
        entities: [],
        dispatched: 5
      }

      {:ok, result} = Dispatch.converge(state, %{})

      assert result.classification == %{"primary" => "dispatch", "severity" => "low"}
      assert result.confidence == 1.0
      assert result.summary == "Dispatched 5 events"
      assert result.findings == []
      assert result.outputs == []
    end
  end
end

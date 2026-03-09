defmodule Cyclium.TriggerInteractiveTest do
  use ExUnit.Case, async: true

  alias Cyclium.Trigger.Interactive

  describe "Trigger.Interactive struct" do
    test "creates with all fields" do
      trigger = %Interactive{
        conversation_id: "conv_1",
        message: "hello",
        principal: %{"id" => "user_1", "type" => "user"},
        history: [%{"role" => "user", "content" => "hi"}]
      }

      assert trigger.conversation_id == "conv_1"
      assert trigger.message == "hello"
      assert trigger.principal["id"] == "user_1"
      assert length(trigger.history) == 1
    end

    test "defaults principal to nil and history to empty" do
      trigger = %Interactive{conversation_id: "c", message: "hello"}
      assert is_nil(trigger.principal)
      assert trigger.history == []
    end

    test "is included in Trigger type union" do
      # Verify the struct module exists and is pattern-matchable
      trigger = %Interactive{conversation_id: "c", message: "m"}
      assert %Interactive{} = trigger
    end
  end
end

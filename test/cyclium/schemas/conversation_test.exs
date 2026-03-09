defmodule Cyclium.Schemas.ConversationTest do
  use ExUnit.Case, async: true

  alias Cyclium.Schemas.Conversation

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Conversation.changeset(%Conversation{}, %{name: "Test", status: "open"})
      assert cs.valid?
    end

    test "invalid without name" do
      cs = Conversation.changeset(%Conversation{}, %{status: "open"})
      refute cs.valid?
      assert {:name, _} = hd(cs.errors)
    end

    test "invalid with unknown status" do
      cs = Conversation.changeset(%Conversation{}, %{name: "Test", status: "invalid"})
      refute cs.valid?
    end

    test "accepts all valid statuses" do
      for status <- Conversation.statuses() do
        cs = Conversation.changeset(%Conversation{}, %{name: "Test", status: status})
        assert cs.valid?, "Expected status #{status} to be valid"
      end
    end
  end

  describe "JSON decode helpers" do
    test "decode_goal returns parsed map" do
      conv = %Conversation{goal: Jason.encode!(%{"type" => "assist"})}
      assert Conversation.decode_goal(conv) == %{"type" => "assist"}
    end

    test "decode_goal returns nil for nil" do
      assert is_nil(Conversation.decode_goal(%Conversation{goal: nil}))
    end

    test "decode_collected_fields returns empty map for nil" do
      assert Conversation.decode_collected_fields(%Conversation{collected_fields: nil}) == %{}
    end

    test "decode_collected_fields returns parsed map" do
      conv = %Conversation{collected_fields: Jason.encode!(%{"name" => "Alice"})}
      assert Conversation.decode_collected_fields(conv)["name"] == "Alice"
    end

    test "decode_result returns nil for nil" do
      assert is_nil(Conversation.decode_result(%Conversation{result: nil}))
    end

    test "decode_origin returns parsed map" do
      conv = %Conversation{origin: Jason.encode!(%{"type" => "workflow"})}
      assert Conversation.decode_origin(conv)["type"] == "workflow"
    end

    test "decode_audience_target returns parsed map" do
      conv = %Conversation{audience_target: Jason.encode!(%{"mode" => "pool"})}
      assert Conversation.decode_audience_target(conv)["mode"] == "pool"
    end

    test "decode_principal returns parsed map" do
      conv = %Conversation{principal: Jason.encode!(%{"id" => "u1"})}
      assert Conversation.decode_principal(conv)["id"] == "u1"
    end
  end
end

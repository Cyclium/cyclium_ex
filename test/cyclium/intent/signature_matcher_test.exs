defmodule Cyclium.Intent.SignatureMatcherTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{SignatureMatcher, ToolCallStep, ToolSignature}

  @read_sig %ToolSignature{name: "lookup_user", version: 1, side_effect: :read, actions: ["go"]}
  @write_sig %ToolSignature{name: "update_user", version: 1, side_effect: :write, actions: ["go"]}

  @ext_sig %ToolSignature{
    name: "send_email",
    version: 1,
    side_effect: :external_effect,
    actions: ["go"]
  }

  # A read tool with one write action: the per-action class wins for that action.
  @mixed_sig %ToolSignature{
    name: "widgets",
    version: 1,
    side_effect: :read,
    actions: ["lookup", "adjust"],
    action_side_effects: %{"adjust" => :write}
  }

  # The legacy shape: a signature with no action list allows nothing.
  @no_actions_sig %ToolSignature{name: "legacy", version: 1, side_effect: :read}

  @any_sig %ToolSignature{name: "open", version: 1, side_effect: :read, actions: :any}

  defp step(tool, action \\ "go"), do: %ToolCallStep{tool: tool, action: action, args: %{}}

  describe "match/2" do
    test "returns matching signature" do
      assert {:ok, @read_sig} =
               SignatureMatcher.match(step("lookup_user"), [@read_sig, @write_sig])
    end

    test "returns error when no match" do
      assert {:error, :no_matching_signature} =
               SignatureMatcher.match(step("delete_user"), [@read_sig])
    end

    test "denies an action the signature does not list, even on a matching tool" do
      assert {:error, :action_not_allowed} =
               SignatureMatcher.match(step("lookup_user", "delete"), [@read_sig])
    end

    test "a signature with no actions allows none" do
      assert {:error, :action_not_allowed} =
               SignatureMatcher.match(step("legacy"), [@no_actions_sig])
    end

    test "actions: :any allows every action" do
      assert {:ok, @any_sig} = SignatureMatcher.match(step("open", "whatever"), [@any_sig])
    end

    test "an atom action is matched by name" do
      assert {:ok, @read_sig} = SignatureMatcher.match(step("lookup_user", :go), [@read_sig])
    end
  end

  describe "has_side_effects?/2" do
    test "true when any step has write side effect" do
      assert SignatureMatcher.has_side_effects?(
               [step("update_user")],
               [@read_sig, @write_sig]
             )
    end

    test "true when any step has external_effect" do
      assert SignatureMatcher.has_side_effects?(
               [step("send_email")],
               [@read_sig, @ext_sig]
             )
    end

    test "false when all steps are reads" do
      refute SignatureMatcher.has_side_effects?(
               [step("lookup_user")],
               [@read_sig, @write_sig]
             )
    end

    test "false when step has no matching signature" do
      refute SignatureMatcher.has_side_effects?(
               [step("unknown_tool")],
               [@read_sig]
             )
    end

    test "uses the per-action class when the signature declares one" do
      refute SignatureMatcher.has_side_effects?([step("widgets", "lookup")], [@mixed_sig])
      assert SignatureMatcher.has_side_effects?([step("widgets", "adjust")], [@mixed_sig])
    end
  end

  describe "ToolSignature.from_config/1" do
    test "reads actions and per-action side effects from string- or atom-keyed config" do
      sig =
        ToolSignature.from_config(%{
          "name" => "widgets",
          "side_effect" => "read",
          "actions" => [
            %{"name" => "lookup"},
            %{name: :adjust, side_effect: "write"},
            "purge"
          ]
        })

      assert sig.actions == ["lookup", "adjust", "purge"]
      assert sig.action_side_effects == %{"adjust" => :write}
      assert ToolSignature.side_effect_for(sig, "lookup") == :read
      assert ToolSignature.side_effect_for(sig, "adjust") == :write
    end

    test "\"*\" opts a tool into any action" do
      sig =
        ToolSignature.from_config(%{"name" => "open", "side_effect" => "read", "actions" => "*"})

      assert sig.actions == :any
      assert ToolSignature.allows_action?(sig, "anything")
    end

    test "no actions key means no actions" do
      sig = ToolSignature.from_config(%{"name" => "legacy", "side_effect" => "read"})
      assert sig.actions == []
      refute ToolSignature.allows_action?(sig, "go")
    end
  end
end

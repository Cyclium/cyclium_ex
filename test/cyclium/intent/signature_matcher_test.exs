defmodule Cyclium.Intent.SignatureMatcherTest do
  use ExUnit.Case, async: true

  alias Cyclium.Intent.{SignatureMatcher, ToolCallStep, ToolSignature}

  @read_sig %ToolSignature{name: "lookup_user", version: 1, side_effect: :read}
  @write_sig %ToolSignature{name: "update_user", version: 1, side_effect: :write}
  @ext_sig %ToolSignature{name: "send_email", version: 1, side_effect: :external_effect}

  defp step(tool), do: %ToolCallStep{tool: tool, action: "go", args: %{}}

  describe "match/2" do
    test "returns matching signature" do
      assert {:ok, @read_sig} =
               SignatureMatcher.match(step("lookup_user"), [@read_sig, @write_sig])
    end

    test "returns error when no match" do
      assert {:error, :no_matching_signature} =
               SignatureMatcher.match(step("delete_user"), [@read_sig])
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
  end
end

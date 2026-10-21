defmodule Cyclium.Conversations.PrincipalDbTest do
  use Cyclium.DataCase

  alias Cyclium.Conversations
  alias Cyclium.Conversations.{Dispatch, LiveHelpers}

  @owner %{"type" => "user", "id" => "u-1"}
  @other %{"type" => "user", "id" => "u-2"}

  setup do
    start_supervised!(Cyclium.FakeRunner)
    Application.put_env(:cyclium, :runner, Cyclium.FakeRunner)
    on_exit(fn -> Application.delete_env(:cyclium, :runner) end)
    :ok
  end

  defp owned_conversation do
    {:ok, conv} =
      Conversations.start(%{actor_id: "principal_actor", name: "c", principal: @owner})

    conv
  end

  describe "Conversations.get_for_principal/3" do
    test "returns the conversation to its principal and refuses anyone else" do
      conv = owned_conversation()

      assert {:ok, %{id: id}} = Conversations.get_for_principal(conv.id, @owner)
      assert id == conv.id
      assert {:error, :forbidden} = Conversations.get_for_principal(conv.id, @other)
      assert {:error, :forbidden} = Conversations.get_for_principal(conv.id, nil)

      assert {:ok, _} =
               Conversations.get_for_principal(conv.id, @other, skip_principal_check: true)
    end

    test "an unknown or malformed id is not found" do
      assert {:error, :not_found} = Conversations.get_for_principal(Ecto.UUID.generate(), @owner)
      assert {:error, :not_found} = Conversations.get_for_principal("not-a-uuid", @owner)
    end

    test "principal_matches?/2 requires the id and, when both sides carry one, the type" do
      conv = owned_conversation()

      assert Conversations.principal_matches?(conv, %{"id" => "u-1"})
      assert Conversations.principal_matches?(conv, %{type: "user", id: "u-1"})
      refute Conversations.principal_matches?(conv, %{"type" => "service", "id" => "u-1"})
      refute Conversations.principal_matches?(conv, %{"type" => "user", "id" => "u-9"})
    end
  end

  describe "LiveHelpers.load_or_create_conversation/5" do
    test "loading another principal's conversation by id is forbidden" do
      conv = owned_conversation()

      assert {%{id: id}, []} =
               LiveHelpers.load_or_create_conversation(
                 %{"id" => conv.id},
                 :show,
                 "principal_actor",
                 @owner
               )

      assert id == conv.id

      assert {:error, :forbidden} =
               LiveHelpers.load_or_create_conversation(
                 %{"id" => conv.id},
                 :show,
                 "principal_actor",
                 @other
               )
    end
  end

  describe "Dispatch.send_message/3 principal check" do
    test "a principal that does not own the conversation is refused before any episode is created" do
      conv = owned_conversation()

      assert {:error, :forbidden} = Dispatch.send_message(conv.id, "hi", principal: @other)
      assert Cyclium.FakeRunner.enqueued_episodes() == []
    end

    test "an unowned conversation is claimed for the principal that first writes to it" do
      {:ok, conv} = Conversations.start(%{actor_id: "principal_actor", name: "pool"})
      assert is_nil(conv.principal_id)

      # No interactive expectation is registered for this actor, so dispatch
      # stops after the principal step; the claim has already happened.
      assert {:error, :no_interactive_expectation} =
               Dispatch.send_message(conv.id, "hi", principal: @owner)

      assert Conversations.get!(conv.id).principal_id == "u-1"
    end

    test "system: true skips the principal check" do
      conv = owned_conversation()

      assert {:error, :no_interactive_expectation} =
               Dispatch.send_message(conv.id, "hi", principal: @other, system: true)
    end
  end
end

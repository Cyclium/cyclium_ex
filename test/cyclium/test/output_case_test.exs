defmodule Cyclium.Test.OutputCaseTest do
  use ExUnit.Case, async: true
  use Cyclium.Test.OutputCase

  alias Cyclium.TestKit.SampleOutputAdapter

  describe "assert_valid_deliver/4" do
    test "passes for valid adapter" do
      payload = %{channel: "#test", message: "hello"}
      ctx = %{episode_id: Ecto.UUID.generate()}

      result = assert_valid_deliver(SampleOutputAdapter, :slack, payload, ctx)
      assert {:ok, %{ref: _}} = result
    end
  end

  describe "FakeOutputAdapter" do
    setup do
      {:ok, _} = Cyclium.Test.FakeOutputAdapter.start_link()

      on_exit(fn ->
        try do
          if pid = Process.whereis(Cyclium.Test.FakeOutputAdapter), do: Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "returns default success response" do
      assert {:ok, %{ref: "fake"}} =
               Cyclium.Test.FakeOutputAdapter.deliver(:email, %{to: "test"}, %{})
    end

    test "records deliveries" do
      Cyclium.Test.FakeOutputAdapter.deliver(:email, %{to: "a@b.com"}, %{ep: 1})
      Cyclium.Test.FakeOutputAdapter.deliver(:slack, %{channel: "#c"}, %{ep: 2})

      deliveries = Cyclium.Test.FakeOutputAdapter.deliveries()
      assert length(deliveries) == 2
      assert {:slack, %{channel: "#c"}, %{ep: 2}} = hd(deliveries)
    end

    test "returns configured error" do
      Cyclium.Test.FakeOutputAdapter.set_error(:channel_not_found)

      assert {:error, :channel_not_found} =
               Cyclium.Test.FakeOutputAdapter.deliver(:slack, %{}, %{})
    end

    test "reset clears state" do
      Cyclium.Test.FakeOutputAdapter.deliver(:email, %{}, %{})
      Cyclium.Test.FakeOutputAdapter.set_error(:fail)
      Cyclium.Test.FakeOutputAdapter.reset()

      assert Cyclium.Test.FakeOutputAdapter.deliveries() == []

      assert {:ok, %{ref: "fake"}} =
               Cyclium.Test.FakeOutputAdapter.deliver(:email, %{}, %{})
    end
  end
end

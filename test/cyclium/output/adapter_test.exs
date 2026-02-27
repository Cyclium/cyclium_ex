defmodule Cyclium.Output.AdapterTest do
  use ExUnit.Case, async: true

  alias Cyclium.Output.Adapter

  defmodule TestEmailAdapter do
    @behaviour Cyclium.Output.Adapter
    def deliver(_type, _payload, _ctx), do: {:ok, %{message_id: "test"}}
  end

  defmodule TestSlackAdapter do
    @behaviour Cyclium.Output.Adapter
    def deliver(_type, _payload, _ctx), do: {:ok, %{channel: "#test"}}
  end

  setup do
    prev = Application.get_env(:cyclium, :output_adapters)

    Application.put_env(:cyclium, :output_adapters, %{
      email: TestEmailAdapter,
      slack: TestSlackAdapter
    })

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyclium, :output_adapters, prev),
        else: Application.delete_env(:cyclium, :output_adapters)
    end)

    :ok
  end

  describe "resolve/1" do
    test "resolves by atom key" do
      assert Adapter.resolve(:email) == TestEmailAdapter
      assert Adapter.resolve(:slack) == TestSlackAdapter
    end

    test "resolves by string key" do
      assert Adapter.resolve("email") == TestEmailAdapter
      assert Adapter.resolve("slack") == TestSlackAdapter
    end

    test "returns nil for unknown type" do
      assert Adapter.resolve(:webhook) == nil
      assert Adapter.resolve("webhook") == nil
    end
  end

  describe "all/0" do
    test "returns all registered adapter keys" do
      keys = Adapter.all()
      assert :email in keys
      assert :slack in keys
      assert length(keys) == 2
    end
  end

  describe "resolve/1 with no adapters configured" do
    setup do
      prev = Application.get_env(:cyclium, :output_adapters)
      Application.delete_env(:cyclium, :output_adapters)
      on_exit(fn -> if prev, do: Application.put_env(:cyclium, :output_adapters, prev) end)
      :ok
    end

    test "returns nil when no adapters configured" do
      assert Adapter.resolve(:email) == nil
    end

    test "all/0 returns empty list" do
      assert Adapter.all() == []
    end
  end
end

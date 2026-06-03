defmodule Cyclium.ToolExecTest do
  use ExUnit.Case

  defmodule FakeTool do
    use Cyclium.Tool

    @impl true
    def call(:ping, _args, _ctx), do: {:ok, :pong}
  end

  defmodule ModuleRegistry do
    def tool_for(:thing), do: Cyclium.ToolExecTest.FakeTool
    def tool_for(_), do: nil
  end

  @ctx %{episode: %Cyclium.Schemas.Episode{actor_id: "tool_exec_test_actor"}}

  setup do
    on_exit(fn -> Application.delete_env(:cyclium, :capability_registry) end)
    :ok
  end

  describe "capability_registry resolution" do
    test "resolves a tool from a map registry" do
      Application.put_env(:cyclium, :capability_registry, %{thing: FakeTool})
      assert {:ok, :pong, 0, _redacted} = Cyclium.ToolExec.call(:thing, :ping, %{}, @ctx)
    end

    test "resolves a tool from a module registry implementing tool_for/1" do
      Application.put_env(:cyclium, :capability_registry, ModuleRegistry)
      assert {:ok, :pong, 0, _redacted} = Cyclium.ToolExec.call(:thing, :ping, %{}, @ctx)
    end

    test "returns :no_tool_for_capability when nothing matches" do
      Application.put_env(:cyclium, :capability_registry, %{other: FakeTool})
      assert {:error, :no_tool_for_capability} = Cyclium.ToolExec.call(:thing, :ping, %{}, @ctx)
    end

    test "returns :no_tool_for_capability when registry is unset" do
      assert {:error, :no_tool_for_capability} = Cyclium.ToolExec.call(:thing, :ping, %{}, @ctx)
    end
  end
end

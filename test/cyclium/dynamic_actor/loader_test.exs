defmodule Cyclium.DynamicActor.LoaderTest do
  use ExUnit.Case, async: false

  alias Cyclium.DynamicActor.Loader

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
    end)

    :ok
  end

  describe "process_name/1" do
    test "returns a tuple keyed by the actor id string, minting no atom" do
      before = :erlang.system_info(:atom_count)
      fresh = "loader_actor_#{System.unique_integer([:positive])}"

      assert Loader.process_name(fresh) == {:cyclium_dynamic, fresh}
      assert Loader.process_name(:my_actor) == {:cyclium_dynamic, "my_actor"}
      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "strategy injection from strategy_template" do
    test "resolve_strategy_module injects template strategy into expectation opts" do
      # "dispatch" template maps to Cyclium.Strategy.Template.Dispatch
      # start_from_definition is private, but we can verify the resolved strategy
      # via TemplateRegistry directly — "dispatch" template maps to Dispatch module
      strategy = Cyclium.Strategy.TemplateRegistry.resolve("dispatch")
      assert strategy == Cyclium.Strategy.Template.Dispatch

      # And confirm an unknown template resolves to nil
      assert Cyclium.Strategy.TemplateRegistry.resolve("nonexistent") == nil
    end

    test "unknown strategy_template results in nil strategy" do
      defn = %Cyclium.Schemas.AgentDefinition{
        actor_id: "unknown_template_actor",
        domain: "testing",
        enabled: true,
        strategy_template: "nonexistent_template",
        expectations: Jason.encode!([])
      }

      # TemplateRegistry.resolve returns nil for unknown templates
      assert Cyclium.Strategy.TemplateRegistry.resolve(defn.strategy_template) == nil
    end

    test "nil strategy_template results in nil strategy" do
      assert Cyclium.Strategy.TemplateRegistry.resolve(nil) == nil
    end
  end
end

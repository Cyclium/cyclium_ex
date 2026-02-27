defmodule Cyclium.Strategy.TemplateRegistryTest do
  use ExUnit.Case, async: true

  alias Cyclium.Strategy.TemplateRegistry

  describe "resolve/1" do
    test "resolves observe_synthesize_converge" do
      assert TemplateRegistry.resolve("observe_synthesize_converge") ==
               Cyclium.Strategy.Template.ObserveSynthesizeConverge
    end

    test "resolves observe_classify_converge" do
      assert TemplateRegistry.resolve("observe_classify_converge") ==
               Cyclium.Strategy.Template.ObserveClassifyConverge
    end

    test "resolves dispatch" do
      assert TemplateRegistry.resolve("dispatch") ==
               Cyclium.Strategy.Template.Dispatch
    end

    test "returns nil for unknown template" do
      assert TemplateRegistry.resolve("unknown") == nil
    end

    test "returns nil for non-string input" do
      assert TemplateRegistry.resolve(nil) == nil
      assert TemplateRegistry.resolve(:atom) == nil
    end
  end
end

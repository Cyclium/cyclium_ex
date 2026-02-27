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

    test "resolves custom templates from application config" do
      defmodule CustomFakeTemplate do
        @behaviour Cyclium.EpisodeRunner.Strategy
        def init(_, _), do: {:ok, %{}}
        def next_step(_, _), do: :converge
        def handle_result(s, _, _), do: {:ok, s}
        def converge(_, _), do: {:ok, %Cyclium.ConvergeResult{}}
      end

      Application.put_env(:cyclium, :strategy_templates, %{
        "custom_test_template" => CustomFakeTemplate
      })

      assert TemplateRegistry.resolve("custom_test_template") == CustomFakeTemplate

      # Built-ins still work alongside custom
      assert TemplateRegistry.resolve("dispatch") == Cyclium.Strategy.Template.Dispatch

      Application.delete_env(:cyclium, :strategy_templates)
    end

    test "custom template overrides built-in with same name" do
      defmodule OverrideTemplate do
        @behaviour Cyclium.EpisodeRunner.Strategy
        def init(_, _), do: {:ok, %{}}
        def next_step(_, _), do: :converge
        def handle_result(s, _, _), do: {:ok, s}
        def converge(_, _), do: {:ok, %Cyclium.ConvergeResult{}}
      end

      Application.put_env(:cyclium, :strategy_templates, %{
        "dispatch" => OverrideTemplate
      })

      assert TemplateRegistry.resolve("dispatch") == OverrideTemplate

      Application.delete_env(:cyclium, :strategy_templates)
    end
  end
end

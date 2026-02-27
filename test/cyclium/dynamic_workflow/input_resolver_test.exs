defmodule Cyclium.DynamicWorkflow.InputResolverTest do
  use ExUnit.Case, async: true

  alias Cyclium.DynamicWorkflow.InputResolver

  describe "resolve/3" do
    test "resolves trigger paths" do
      input_map = %{"order_id" => "trigger.order_id", "name" => "trigger.customer.name"}
      trigger_ref = %{"order_id" => "abc123", "customer" => %{"name" => "Jane"}}
      prior = %{}

      result = InputResolver.resolve(input_map, trigger_ref, prior)

      assert result["order_id"] == "abc123"
      assert result["name"] == "Jane"
    end

    test "resolves prior step paths" do
      input_map = %{
        "risk" => "prior.compliance_check.classification",
        "summary" => "prior.compliance_check.summary"
      }

      trigger_ref = %{}

      prior = %{
        compliance_check: %{
          classification: "high",
          summary: "Flagged for review"
        }
      }

      result = InputResolver.resolve(input_map, trigger_ref, prior)

      assert result["risk"] == "high"
      assert result["summary"] == "Flagged for review"
    end

    test "resolves nested prior paths" do
      input_map = %{"primary_class" => "prior.analyze.classification.primary"}
      trigger_ref = %{}

      prior = %{
        analyze: %{
          classification: %{"primary" => "healthy", "severity" => "low"}
        }
      }

      result = InputResolver.resolve(input_map, trigger_ref, prior)

      assert result["primary_class"] == "healthy"
    end

    test "passes static values through" do
      input_map = %{
        "mode" => "fast",
        "count" => 42,
        "order_id" => "trigger.order_id"
      }

      trigger_ref = %{"order_id" => "xyz"}
      prior = %{}

      result = InputResolver.resolve(input_map, trigger_ref, prior)

      assert result["mode"] == "fast"
      assert result["count"] == 42
      assert result["order_id"] == "xyz"
    end

    test "returns nil for missing trigger paths" do
      input_map = %{"missing" => "trigger.nonexistent"}
      result = InputResolver.resolve(input_map, %{}, %{})
      assert result["missing"] == nil
    end

    test "returns nil for missing prior step" do
      input_map = %{"missing" => "prior.nonexistent_step.field"}
      result = InputResolver.resolve(input_map, %{}, %{})
      assert result["missing"] == nil
    end

    test "returns nil for missing nested path" do
      input_map = %{"deep" => "trigger.a.b.c.d"}
      trigger_ref = %{"a" => %{"b" => nil}}
      result = InputResolver.resolve(input_map, trigger_ref, %{})
      assert result["deep"] == nil
    end

    test "handles nil input_map" do
      assert InputResolver.resolve(nil, %{}, %{}) == %{}
    end

    test "handles empty input_map" do
      assert InputResolver.resolve(%{}, %{}, %{}) == %{}
    end

    test "resolves atom keys in trigger_ref" do
      input_map = %{"id" => "trigger.project_id"}
      trigger_ref = %{project_id: "123"}

      result = InputResolver.resolve(input_map, trigger_ref, %{})
      assert result["id"] == "123"
    end

    test "mixed trigger and prior resolution" do
      input_map = %{
        "vendor_id" => "trigger.vendor_id",
        "risk_level" => "prior.compliance.risk",
        "timeout" => 30000
      }

      trigger_ref = %{"vendor_id" => "v-456"}
      prior = %{compliance: %{risk: "medium"}}

      result = InputResolver.resolve(input_map, trigger_ref, prior)

      assert result["vendor_id"] == "v-456"
      assert result["risk_level"] == "medium"
      assert result["timeout"] == 30000
    end
  end
end

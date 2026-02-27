defmodule Cyclium.Findings.ConfigTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings.Config

  setup do
    Config.ensure_table()

    on_exit(fn ->
      Application.delete_env(:cyclium, :finding_enrichment)
      Application.delete_env(:cyclium, :escalation_rules)
    end)

    :ok
  end

  describe "register/3 and get/3" do
    test "stores and retrieves config" do
      Config.register("actor_a", "exp_1", %{
        enrichment: fn _, _ -> :skip end,
        default_ttl_seconds: 3600
      })

      config = Config.get("actor_a", "exp_1")
      assert config.default_ttl_seconds == 3600
      assert is_function(config.enrichment, 2)
    end

    test "returns nil for unregistered expectation" do
      assert Config.get("nonexistent", "nope") == nil
    end
  end

  describe "enrichment_for/2" do
    test "returns per-expectation enrichment over app env" do
      callback = fn _, _ -> {:ok, %{summary: "dsl"}} end
      Config.register("actor_e", "exp_e", %{enrichment: callback})
      Application.put_env(:cyclium, :finding_enrichment, fn _, _ -> {:ok, %{summary: "app"}} end)

      assert Config.enrichment_for("actor_e", "exp_e") == callback
    end

    test "falls back to app env when no per-expectation config" do
      app_callback = fn _, _ -> {:ok, %{summary: "app"}} end
      Application.put_env(:cyclium, :finding_enrichment, app_callback)

      assert Config.enrichment_for("no_actor", "no_exp") == app_callback
    end

    test "returns nil when nothing configured" do
      Application.delete_env(:cyclium, :finding_enrichment)
      assert Config.enrichment_for("empty", "empty") == nil
    end
  end

  describe "default_ttl_for/2" do
    test "returns TTL from registered config" do
      Config.register("actor_t", "exp_t", %{default_ttl_seconds: 7200})
      assert Config.default_ttl_for("actor_t", "exp_t") == 7200
    end

    test "returns nil when not registered" do
      assert Config.default_ttl_for("none", "none") == nil
    end

    test "returns nil when registered without ttl" do
      Config.register("actor_no_ttl", "exp_no_ttl", %{enrichment: fn _, _ -> :skip end})
      assert Config.default_ttl_for("actor_no_ttl", "exp_no_ttl") == nil
    end
  end

  describe "all_escalation_rules/0" do
    test "collects rules from registered expectations" do
      Config.register("actor_1", "exp_1", %{
        escalation_rules: %{
          "vendor_delay" => [%{after_minutes: 60, escalate_to: :high}]
        }
      })

      Config.register("actor_2", "exp_2", %{
        escalation_rules: %{
          "service_outage" => [%{after_minutes: 30, escalate_to: :critical}]
        }
      })

      rules = Config.all_escalation_rules()
      assert Map.has_key?(rules, "vendor_delay")
      assert Map.has_key?(rules, "service_outage")
    end

    test "falls back to app env when no per-expectation rules" do
      Application.put_env(:cyclium, :escalation_rules, %{
        "fallback_class" => [%{after_minutes: 120, escalate_to: :high}]
      })

      # Clear any registered rules by re-creating table
      :ets.delete_all_objects(:cyclium_findings_config)

      rules = Config.all_escalation_rules()
      assert Map.has_key?(rules, "fallback_class")
    end

    test "prefers per-expectation rules over app env" do
      Application.put_env(:cyclium, :escalation_rules, %{
        "from_app" => [%{after_minutes: 60, escalate_to: :high}]
      })

      Config.register("actor_p", "exp_p", %{
        escalation_rules: %{
          "from_dsl" => [%{after_minutes: 30, escalate_to: :critical}]
        }
      })

      rules = Config.all_escalation_rules()
      # Should have DSL rules, not app env
      assert Map.has_key?(rules, "from_dsl")
      refute Map.has_key?(rules, "from_app")
    end
  end
end

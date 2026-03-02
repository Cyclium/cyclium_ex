defmodule Cyclium.Findings.ConfigTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings.Config

  setup do
    Config.ensure_table()

    on_exit(fn ->
      Application.delete_env(:cyclium, :finding_enrichment)
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

  describe "escalation_pairs/0" do
    test "collects scoped rules from registered expectations" do
      :ets.delete_all_objects(:cyclium_findings_config)

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

      pairs = Config.escalation_pairs()
      assert length(pairs) == 2

      assert Enum.any?(pairs, fn {a, e, _} -> a == "actor_1" and e == "exp_1" end)
      assert Enum.any?(pairs, fn {a, e, _} -> a == "actor_2" and e == "exp_2" end)
    end

    test "excludes expectations without escalation rules" do
      :ets.delete_all_objects(:cyclium_findings_config)

      Config.register("actor_a", "exp_a", %{default_ttl_seconds: 3600})

      Config.register("actor_b", "exp_b", %{
        escalation_rules: %{
          "delay" => [%{after_minutes: 60, escalate_to: :high}]
        }
      })

      pairs = Config.escalation_pairs()
      assert length(pairs) == 1
      assert [{_actor, _exp, rules}] = pairs
      assert Map.has_key?(rules, "delay")
    end

    test "returns empty list when nothing registered" do
      :ets.delete_all_objects(:cyclium_findings_config)
      assert Config.escalation_pairs() == []
    end
  end
end

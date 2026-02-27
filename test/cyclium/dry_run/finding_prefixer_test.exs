defmodule Cyclium.DryRun.FindingPrefixerTest do
  use ExUnit.Case, async: true

  alias Cyclium.DryRun.FindingPrefixer

  describe "persist_prefix/1" do
    test "returns default prefix for true" do
      episode = %{dry_run_opts: %{"persist_findings" => true}}
      assert FindingPrefixer.persist_prefix(episode) == "dry_run"
    end

    test "returns custom prefix for string value" do
      episode = %{dry_run_opts: %{"persist_findings" => "experiment1"}}
      assert FindingPrefixer.persist_prefix(episode) == "experiment1"
    end

    test "returns nil when persist_findings is false" do
      episode = %{dry_run_opts: %{"persist_findings" => false}}
      assert FindingPrefixer.persist_prefix(episode) == nil
    end

    test "returns nil when persist_findings is missing" do
      episode = %{dry_run_opts: %{}}
      assert FindingPrefixer.persist_prefix(episode) == nil
    end

    test "returns nil when dry_run_opts is nil" do
      episode = %{dry_run_opts: nil}
      assert FindingPrefixer.persist_prefix(episode) == nil
    end

    test "returns nil when episode has no dry_run_opts key" do
      episode = %{}
      assert FindingPrefixer.persist_prefix(episode) == nil
    end

    test "returns nil for empty string prefix" do
      episode = %{dry_run_opts: %{"persist_findings" => ""}}
      assert FindingPrefixer.persist_prefix(episode) == nil
    end
  end

  describe "prefix_actions/2" do
    test "prefixes :raise finding_key and actor_id" do
      actions = [{:raise, %{finding_key: "po_stalled:PO-123", actor_id: "po_monitor"}}]

      [{:raise, params}] = FindingPrefixer.prefix_actions(actions, "dry_run")

      assert params.finding_key == "dry_run:po_stalled:PO-123"
      assert params.actor_id == "dry_run:po_monitor"
    end

    test "handles nil actor_id in :raise" do
      actions = [{:raise, %{finding_key: "key1", actor_id: nil}}]

      [{:raise, params}] = FindingPrefixer.prefix_actions(actions, "test")

      assert params.finding_key == "test:key1"
      assert params.actor_id == nil
    end

    test "handles :raise without actor_id key" do
      actions = [{:raise, %{finding_key: "key1"}}]

      [{:raise, params}] = FindingPrefixer.prefix_actions(actions, "test")

      assert params.finding_key == "test:key1"
      assert Map.get(params, :actor_id) == nil
    end

    test "prefixes :update key" do
      actions = [{:update, "po_stalled:PO-123", %{severity: "high"}}]

      [{:update, key, changes}] = FindingPrefixer.prefix_actions(actions, "dry_run")

      assert key == "dry_run:po_stalled:PO-123"
      assert changes == %{severity: "high"}
    end

    test "prefixes :clear key" do
      actions = [{:clear, "po_stalled:PO-123"}]

      [{:clear, key}] = FindingPrefixer.prefix_actions(actions, "dry_run")

      assert key == "dry_run:po_stalled:PO-123"
    end

    test "prefixes :clear key with reason" do
      actions = [{:clear, "po_stalled:PO-123", "resolved"}]

      [{:clear, key, reason}] = FindingPrefixer.prefix_actions(actions, "exp1")

      assert key == "exp1:po_stalled:PO-123"
      assert reason == "resolved"
    end

    test "handles mixed actions with custom prefix" do
      actions = [
        {:raise, %{finding_key: "key1", actor_id: "actor1"}},
        {:update, "key2", %{confidence: 0.9}},
        {:clear, "key3"},
        {:clear, "key4", "no longer relevant"}
      ]

      result = FindingPrefixer.prefix_actions(actions, "batch42")

      assert [{:raise, raise_params}, {:update, ukey, _}, {:clear, ckey1}, {:clear, ckey2, _}] =
               result

      assert raise_params.finding_key == "batch42:key1"
      assert raise_params.actor_id == "batch42:actor1"
      assert ukey == "batch42:key2"
      assert ckey1 == "batch42:key3"
      assert ckey2 == "batch42:key4"
    end

    test "preserves all other params in :raise" do
      actions = [
        {:raise,
         %{
           finding_key: "k1",
           actor_id: "a1",
           class: "stalled",
           severity: "high",
           summary: "PO is stalled"
         }}
      ]

      [{:raise, params}] = FindingPrefixer.prefix_actions(actions, "dry_run")

      assert params.class == "stalled"
      assert params.severity == "high"
      assert params.summary == "PO is stalled"
    end
  end
end

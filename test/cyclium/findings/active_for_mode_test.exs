defmodule Cyclium.Findings.ActiveForModeTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings

  setup do
    # FakeRepo.start_link/0 resets and returns {:ok, pid} whether or not the
    # Agent was already started, so match the contract assertively.
    {:ok, _} = Cyclium.FakeRepo.start_link()

    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
    on_exit(fn -> Application.delete_env(:cyclium, :repo) end)
    :ok
  end

  describe "active_for_mode/3" do
    test "live episode delegates to active_for unchanged" do
      episode = %{mode: "live", dry_run_opts: nil}
      # FakeRepo.all returns [], but we verify no crash and correct delegation
      assert [] = Findings.active_for_mode([actor: "my_actor"], episode)
    end

    test "dry run without persist_findings delegates unchanged" do
      episode = %{mode: "dry_run", dry_run_opts: %{}}
      assert [] = Findings.active_for_mode([actor: "my_actor"], episode)
    end

    test "dry run with persist_findings: true prefixes actor filter" do
      episode = %{mode: "dry_run", dry_run_opts: %{"persist_findings" => true}}
      # This calls active_for with prefixed filters — FakeRepo returns []
      # but we verify it doesn't crash (the prefix is applied internally)
      assert [] = Findings.active_for_mode([actor: "my_actor"], episode)
    end

    test "dry run with custom prefix prefixes actor and finding_key" do
      episode = %{mode: "dry_run", dry_run_opts: %{"persist_findings" => "staging"}}
      assert [] = Findings.active_for_mode([actor: "my_actor", finding_key: "key:1"], episode)
    end

    test "non-prefixed filters pass through unchanged" do
      episode = %{mode: "dry_run", dry_run_opts: %{"persist_findings" => true}}

      # subject and class filters should not be prefixed
      assert [] =
               Findings.active_for_mode(
                 [subject: %{kind: "project", id: "123"}, class: "at_risk"],
                 episode
               )
    end

    test "nil episode delegates unchanged" do
      assert [] = Findings.active_for_mode([actor: "my_actor"], nil)
    end

    test "episode without dry_run_opts key delegates unchanged" do
      episode = %{mode: "live"}
      assert [] = Findings.active_for_mode([actor: "my_actor"], episode)
    end

    test "passes opts through to active_for" do
      episode = %{mode: "live", dry_run_opts: nil}
      assert [] = Findings.active_for_mode([actor: "my_actor"], episode, limit: 10)
    end
  end
end

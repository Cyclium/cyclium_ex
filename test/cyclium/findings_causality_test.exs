defmodule Cyclium.FindingsCausalityTest do
  use ExUnit.Case, async: false

  alias Cyclium.Findings
  alias Cyclium.Schemas.Finding

  setup do
    case Cyclium.FakeRepo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
    end)

    episode = %Cyclium.Schemas.Episode{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      status: :running
    }

    %{episode: episode}
  end

  describe "persist_finding with caused_by_key" do
    test "stores caused_by_key on new finding", %{episode: episode} do
      params = %{
        actor_id: "test_actor",
        finding_key: "child:#{Ecto.UUID.generate()}",
        class: "child_issue",
        severity: :high,
        confidence: 0.9,
        summary: "Child finding",
        caused_by_key: "parent:root_issue"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.caused_by_key == "parent:root_issue"
      assert finding.status == :active
    end

    test "finding without caused_by_key has nil", %{episode: episode} do
      params = %{
        actor_id: "test_actor",
        finding_key: "root:#{Ecto.UUID.generate()}",
        class: "root_issue",
        severity: :medium,
        confidence: 0.85,
        summary: "Root finding"
      }

      assert {:ok, finding} = Findings.persist_finding({:raise, params}, episode)
      assert finding.caused_by_key == nil
    end
  end

  describe "caused_by/1" do
    test "returns empty list when no children found" do
      # FakeRepo.all returns [] — verifies the query path compiles and runs
      assert Findings.caused_by("nonexistent:key") == []
    end
  end

  describe "causal_chain/2" do
    test "returns empty list when finding not found" do
      # FakeRepo.one returns nil — verifies chain walking handles missing findings
      assert Findings.causal_chain("nonexistent:key") == []
    end

    test "respects max_depth option" do
      assert Findings.causal_chain("any:key", max_depth: 0) == []
    end
  end

  describe "root_cause/1" do
    test "returns nil when finding not found" do
      assert Findings.root_cause("nonexistent:key") == nil
    end
  end

  describe "Finding schema" do
    test "caused_by_key field exists on struct" do
      finding = %Finding{}
      assert Map.has_key?(finding, :caused_by_key)
      assert finding.caused_by_key == nil
    end

    test "expires_at field exists on struct" do
      finding = %Finding{}
      assert Map.has_key?(finding, :expires_at)
      assert finding.expires_at == nil
    end

    test "changeset accepts caused_by_key" do
      cs =
        Finding.changeset(%Finding{}, %{
          actor_id: "test",
          finding_key: "test:key",
          status: :active,
          class: "test",
          raised_by_episode_id: Ecto.UUID.generate(),
          raised_at: DateTime.utc_now() |> DateTime.truncate(:second),
          caused_by_key: "parent:key"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :caused_by_key) == "parent:key"
    end

    test "changeset accepts expires_at" do
      expires = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      cs =
        Finding.changeset(%Finding{}, %{
          actor_id: "test",
          finding_key: "test:key",
          status: :active,
          class: "test",
          raised_by_episode_id: Ecto.UUID.generate(),
          raised_at: DateTime.utc_now() |> DateTime.truncate(:second),
          expires_at: expires
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :expires_at) == expires
    end
  end
end

defmodule Cyclium.FindingsRecordDbTest do
  @moduledoc """
  `Findings.record/2` persists a finding action, broadcasts its `finding.*`
  event and journals its step, from a tool as from post-converge; a supersede
  retires the active finding and raises its replacement.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, Episodes, EpisodeRunner, Findings}
  alias Cyclium.Schemas.Finding

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.FindingsRecordTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.FindingsRecordTestPubSub)
    on_exit(fn -> Application.delete_env(:cyclium, :pubsub) end)
    :ok
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: "record_actor",
        finding_key: "record:#{System.unique_integer([:positive])}",
        class: "test_class",
        severity: :high,
        summary: "A finding"
      },
      overrides
    )
  end

  defp finding_steps(episode_id) do
    episode_id
    |> Episodes.list_steps()
    |> Enum.filter(
      &(&1.kind in [:finding_raised, :finding_updated, :finding_cleared, :finding_superseded])
    )
    |> Enum.map(&{&1.kind, &1.result_ref["finding_key"]})
  end

  describe "record/2" do
    test "a raise is persisted, broadcast and journaled" do
      episode = insert_episode(%{conversation_id: Ecto.UUID.generate()})
      Cyclium.Bus.subscribe("finding.raised")
      p = params()

      assert {:ok, finding} = Findings.record({:raise, p}, episode)

      assert_receive {:bus, "finding.raised", payload}
      assert payload.finding_id == finding.id
      assert payload.finding_key == p.finding_key
      assert payload.episode_id == episode.id
      assert payload.conversation_id == episode.conversation_id
      assert finding_steps(episode.id) == [{:finding_raised, p.finding_key}]
    end

    test "update and clear announce their own events and steps" do
      episode = insert_episode()
      Cyclium.Bus.subscribe("finding.updated")
      Cyclium.Bus.subscribe("finding.cleared")
      p = params()

      {:ok, _} = Findings.persist_finding({:raise, p}, episode)
      assert {:ok, _} = Findings.record({:update, p.finding_key, %{confidence: 0.4}}, episode)
      assert {:ok, _} = Findings.record({:clear, p.finding_key, "gone"}, episode)

      assert_receive {:bus, "finding.updated", %{finding_key: key}} when key == p.finding_key
      assert_receive {:bus, "finding.cleared", %{finding_key: ^key}}

      assert finding_steps(episode.id) == [
               {:finding_updated, p.finding_key},
               {:finding_cleared, p.finding_key}
             ]
    end

    test "an idempotent clear announces nothing" do
      episode = insert_episode()
      Cyclium.Bus.subscribe("finding.cleared")

      assert :ok = Findings.record({:clear, "record:missing"}, episode)

      refute_receive {:bus, "finding.cleared", _}
      assert finding_steps(episode.id) == []
    end

    test "a failed write announces nothing" do
      episode = insert_episode()

      assert {:error, :not_found} = Findings.record({:update, "record:missing", %{}}, episode)
      assert finding_steps(episode.id) == []
    end
  end

  describe "supersede" do
    test "retires the active finding and raises its replacement, announcing both" do
      episode = insert_episode()
      Cyclium.Bus.subscribe("finding.superseded")
      Cyclium.Bus.subscribe("finding.raised")
      old = params()
      new = params()

      {:ok, original} = Findings.persist_finding({:raise, old}, episode)
      assert {:ok, raised} = Findings.record({:supersede, old.finding_key, new}, episode)

      assert Repo.get!(Finding, original.id).status == :superseded
      assert Repo.get!(Finding, original.id).archived_at
      assert raised.status == :active
      assert raised.finding_key == new.finding_key

      assert_receive {:bus, "finding.superseded", %{finding_id: id}} when id == original.id
      assert_receive {:bus, "finding.raised", %{finding_id: id}} when id == raised.id

      assert finding_steps(episode.id) == [
               {:finding_superseded, old.finding_key},
               {:finding_raised, new.finding_key}
             ]
    end

    test "the replacement may reuse the key, any number of times" do
      episode = insert_episode()
      p = params()

      {:ok, first} = Findings.persist_finding({:raise, p}, episode)
      {:ok, second} = Findings.record({:supersede, p.finding_key, p}, episode)
      {:ok, third} = Findings.record({:supersede, p.finding_key, p}, episode)

      assert length(Enum.uniq([first.id, second.id, third.id])) == 3

      statuses =
        Finding
        |> Repo.all()
        |> Enum.filter(&(&1.finding_key == p.finding_key))
        |> Enum.map(& &1.status)
        |> Enum.frequencies()

      assert statuses == %{superseded: 2, active: 1}
    end

    test "with no active finding under the key, it only raises" do
      episode = insert_episode()
      new = params()

      assert {:ok, raised} = Findings.record({:supersede, "record:absent", new}, episode)
      assert raised.finding_key == new.finding_key
      assert finding_steps(episode.id) == [{:finding_raised, new.finding_key}]
    end

    test "a replacement that fails to raise leaves the original active" do
      episode = insert_episode()
      old = params()
      {:ok, original} = Findings.persist_finding({:raise, old}, episode)

      assert_raise KeyError, fn ->
        Findings.record(
          {:supersede, old.finding_key, Map.delete(params(), :finding_key)},
          episode
        )
      end

      assert Repo.get!(Finding, original.id).status == :active
      assert finding_steps(episode.id) == []
    end

    test "persist_finding/2 supersedes without announcing" do
      episode = insert_episode()
      Cyclium.Bus.subscribe("finding.superseded")
      old = params()
      {:ok, _} = Findings.persist_finding({:raise, old}, episode)

      assert {:ok, _} = Findings.persist_finding({:supersede, old.finding_key, params()}, episode)

      refute_receive {:bus, "finding.superseded", _}
      assert finding_steps(episode.id) == []
    end
  end

  defmodule RecordingTool do
    use Cyclium.Tool

    @impl true
    def call(:flag, %{"key" => key}, %{episode: episode}) do
      Findings.record(
        {:raise,
         %{finding_key: key, actor_id: "record_actor", class: "flagged", summary: "Flagged"}},
        episode
      )

      {:ok, %{flagged: key}}
    end
  end

  defmodule FlagStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{done: false}}

    def next_step(%{done: false}, _ctx),
      do: {:tool_call, :recorder, :flag, %{"key" => "record:tool"}}

    def next_step(_state, _ctx), do: :converge

    def handle_result(state, _step, _result), do: {:ok, %{state | done: true}}

    def converge(_state, _ctx),
      do:
        {:ok,
         %ConvergeResult{
           summary: "ok",
           findings: [{:supersede, "record:tool", params(%{finding_key: "record:tool:v2"})}]
         }}

    defp params(overrides) do
      Map.merge(
        %{actor_id: "record_actor", class: "flagged", summary: "Flagged again"},
        overrides
      )
    end
  end

  test "a tool's finding is journaled before its tool_call step, as post-converge's are after it" do
    Application.put_env(:cyclium, :capability_registry, %{recorder: RecordingTool})
    on_exit(fn -> Application.delete_env(:cyclium, :capability_registry) end)

    episode =
      insert_episode(%{
        actor_id: "record_actor",
        budget: %{"max_turns" => 10, "max_tokens" => 1_000, "max_wall_ms" => 10_000},
        log_strategy: "full_debug"
      })

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, FlagStrategy, %{done: false})

    kinds =
      episode.id
      |> Episodes.list_steps()
      |> Enum.map(& &1.kind)
      |> Enum.filter(&(&1 in [:tool_call, :finding_raised, :finding_superseded]))

    assert kinds == [:finding_raised, :tool_call, :finding_superseded, :finding_raised]
  end

  test "a dry run prefixes both keys of a supersede" do
    assert [{:supersede, "dry_run:a", %{finding_key: "dry_run:b", actor_id: "dry_run:x"}}] =
             Cyclium.DryRun.FindingPrefixer.prefix_actions(
               [{:supersede, "a", %{finding_key: "b", actor_id: "x"}}],
               "dry_run"
             )
  end
end

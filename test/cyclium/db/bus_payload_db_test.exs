defmodule Cyclium.BusPayloadDbTest do
  @moduledoc """
  Integration tests asserting that Bus payloads carry the fields subscribers
  need without a DB round-trip:

    * `episode.failed` includes `error_class` / `error_detail`
    * `episode.completed` includes `summary` / `classification`
    * `episode.step_journaled` includes `tool_name` / `error_class` / `cost_tokens`
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, EpisodeRunner}

  defmodule FakeTool do
    use Cyclium.Tool

    @impl true
    def call(:read_record, _args, _ctx), do: {:ok, %{found: true}}
  end

  defmodule FakeRegistry do
    def tool_for(:data_source), do: FakeTool
    def tool_for(_), do: nil
  end

  defmodule ToolThenConvergeStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{phase: :call}}

    @impl true
    def next_step(%{phase: :call}, _ctx),
      do: {:tool_call, :data_source, :read_record, %{"record_id" => "r-1"}}

    def next_step(%{phase: :done}, _ctx), do: :converge

    @impl true
    def handle_result(%{phase: :call} = state, _step, {:ok, _}),
      do: {:ok, %{state | phase: :done}}

    @impl true
    def converge(_state, _ctx) do
      {:ok,
       %ConvergeResult{
         classification: %{"primary" => "ok"},
         confidence: 1.0,
         summary: "all good",
         findings: [],
         outputs: []
       }}
    end
  end

  defmodule AbortStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    @impl true
    def init(_episode, _trigger), do: {:ok, %{}}

    @impl true
    def next_step(_state, _ctx),
      do: {:tool_call, :data_source, :read_record, %{"record_id" => "r-1"}}

    @impl true
    def handle_result(_state, _step, {:ok, _}), do: {:abort, :custom_failure}

    @impl true
    def converge(_state, _ctx), do: {:ok, %ConvergeResult{}}
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.BusPayloadTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.BusPayloadTestPubSub)
    Application.put_env(:cyclium, :capability_registry, FakeRegistry)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :capability_registry)
    end)

    :ok
  end

  defp run_episode(strategy) do
    episode =
      insert_episode(%{
        actor_id: "bus_payload_actor",
        expectation_id: "do_work",
        budget: %{"max_turns" => 5, "max_tokens" => 1_000, "max_wall_ms" => 10_000},
        log_strategy: "full_debug"
      })

    {episode, EpisodeRunner.execute_loop(episode, strategy, %{phase: :call})}
  end

  test "episode.step_journaled payload includes tool_name and cost_tokens" do
    Cyclium.Bus.subscribe("episode.step_journaled")

    {_episode, _result} = run_episode(ToolThenConvergeStrategy)

    assert_receive {:bus, "episode.step_journaled", %{kind: :tool_call} = payload}
    assert payload.tool_name == "data_source.read_record"
    assert Map.has_key?(payload, :cost_tokens)
    assert Map.has_key?(payload, :error_class)
  end

  test "episode.completed payload includes summary and classification" do
    Cyclium.Bus.subscribe("episode.completed")

    {episode, _result} = run_episode(ToolThenConvergeStrategy)

    assert_receive {:bus, "episode.completed", payload}
    assert payload.episode_id == episode.id
    assert payload.summary == "all good"
    assert payload.classification == %{"primary" => "ok"}
  end

  test "episode.failed payload includes error_class and error_detail on abort" do
    Cyclium.Bus.subscribe("episode.failed")

    {episode, result} = run_episode(AbortStrategy)

    assert {:error, :custom_failure} = result
    assert_receive {:bus, "episode.failed", payload}
    assert payload.episode_id == episode.id
    assert payload.error_class == "custom_failure"
    assert is_map(payload.error_detail)
  end

  test "lifecycle Bus events carry conversation_id" do
    conv_id = Ecto.UUID.generate()

    Cyclium.Bus.subscribe("episode.started")
    Cyclium.Bus.subscribe("episode.step_journaled")
    Cyclium.Bus.subscribe("episode.completed")

    episode =
      insert_episode(%{
        actor_id: "bus_payload_actor",
        expectation_id: "do_work",
        conversation_id: conv_id,
        budget: %{"max_turns" => 5, "max_tokens" => 1_000, "max_wall_ms" => 10_000},
        log_strategy: "full_debug"
      })

    EpisodeRunner.execute_loop(episode, ToolThenConvergeStrategy, %{phase: :call})

    assert_receive {:bus, "episode.started", %{conversation_id: ^conv_id}}
    assert_receive {:bus, "episode.step_journaled", %{conversation_id: ^conv_id}}
    assert_receive {:bus, "episode.completed", %{conversation_id: ^conv_id}}
  end
end

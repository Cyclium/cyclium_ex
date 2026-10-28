defmodule Cyclium.StepTimingDbTest do
  @moduledoc """
  A synthesis step records how long the LLM call took (`cost_ms`), the runner
  broadcasts `episode.step_started` as a tool call or LLM request goes out, and
  `[:cyclium, :step, :synthesis, :start]` fires before the request.
  """
  use Cyclium.DataCase

  alias Cyclium.{ConvergeResult, Episodes, EpisodeRunner}

  defmodule SlowSynth do
    def synthesize(_prompt_ctx, _episode_ctx) do
      Process.sleep(20)

      {:ok,
       %{
         model: "m-1",
         usage: %{
           input_tokens: 10,
           output_tokens: 5,
           cache_creation_input_tokens: 100,
           cache_read_input_tokens: 1_000
         }
       }}
    end
  end

  defmodule FailingSynth do
    def synthesize(_prompt_ctx, _episode_ctx) do
      Process.sleep(20)
      {:error, :rate_limited, "slow down"}
    end
  end

  defmodule FakeTool do
    use Cyclium.Tool

    @impl true
    def call(:read_record, _args, _ctx), do: {:ok, %{found: true}}
  end

  defmodule FakeRegistry do
    def tool_for(:data_source), do: FakeTool
    def tool_for(_), do: nil
  end

  defmodule SynthStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy

    def init(_episode, _trigger), do: {:ok, %{phase: :synth}}

    def next_step(%{phase: :synth}, _ctx), do: {:synthesize, %{task: :interpret}}
    def next_step(%{phase: :tool}, _ctx), do: {:tool_call, :data_source, :read_record, %{}}
    def next_step(%{phase: :done}, _ctx), do: :converge

    def handle_result(%{phase: :synth} = state, _step, {:ok, _}),
      do: {:ok, %{state | phase: :tool}}

    def handle_result(%{phase: :synth}, _step, {:error, reason}), do: {:abort, reason}
    def handle_result(%{phase: :tool} = state, _step, _), do: {:ok, %{state | phase: :done}}

    def converge(_state, _ctx) do
      {:ok, %ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.StepTimingTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.StepTimingTestPubSub)
    Application.put_env(:cyclium, :capability_registry, FakeRegistry)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :capability_registry)
    end)

    :ok
  end

  defp run(synth) do
    episode =
      insert_episode(%{
        actor_id: "step_timing_actor",
        expectation_id: "do_work",
        tokens_used: 0,
        budget: %{"max_turns" => 10, "max_tokens" => 100_000, "max_wall_ms" => 10_000},
        log_strategy: "full_debug"
      })

    result =
      EpisodeRunner.execute_loop(episode, SynthStrategy, %{phase: :synth}, synthesizer: synth)

    {episode, result}
  end

  defp synthesis_step(episode_id) do
    Enum.find(Episodes.list_steps(episode_id), &(&1.kind == :synthesis))
  end

  test "a synthesis step records the call's duration as cost_ms" do
    {episode, {:ok, _}} = run(SlowSynth)

    step = synthesis_step(episode.id)
    assert is_integer(step.cost_ms)
    assert step.cost_ms >= 20
  end

  test "a failed synthesis step records cost_ms too" do
    {episode, _} = run(FailingSynth)

    step = synthesis_step(episode.id)
    assert step.error_class == "rate_limited"
    assert step.cost_ms >= 20
  end

  test "cached input counts toward the episode's tokens" do
    {episode, {:ok, _}} = run(SlowSynth)

    assert Episodes.get!(episode.id).tokens_used == 1_115
    assert synthesis_step(episode.id).cost_tokens == 1_115
  end

  test "episode.step_started is broadcast before each synthesis and tool call" do
    Cyclium.Bus.subscribe("episode.step_started")
    Cyclium.Bus.subscribe("episode.step_journaled")

    {episode, {:ok, _}} = run(SlowSynth)
    id = episode.id

    assert_receive {:bus, "episode.step_started", %{kind: :synthesis} = synth}
    assert synth.episode_id == id
    assert synth.actor_id == "step_timing_actor"
    assert synth.expectation_id == "do_work"
    assert synth.tool_name == nil
    assert %DateTime{} = synth.started_at

    assert_receive {:bus, "episode.step_started", %{kind: :tool_call} = tool}
    assert tool.tool_name == "data_source.read_record"
  end

  test "each step's start is broadcast before its journal entry" do
    Cyclium.Bus.subscribe()

    {_episode, {:ok, _}} = run(SlowSynth)

    order =
      collect_bus()
      |> Enum.flat_map(fn
        {"episode.step_started", %{kind: kind}} ->
          [{:started, kind}]

        {"episode.step_journaled", %{kind: kind}} when kind in [:synthesis, :tool_call] ->
          [{:journaled, kind}]

        _ ->
          []
      end)

    assert order == [
             {:started, :synthesis},
             {:journaled, :synthesis},
             {:started, :tool_call},
             {:journaled, :tool_call}
           ]
  end

  defp collect_bus(acc \\ []) do
    receive do
      {:bus, type, payload} -> collect_bus([{type, payload} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "[:cyclium, :step, :synthesis, :start] fires before the completion event" do
    test_pid = self()
    handler = "step-timing-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler,
      [[:cyclium, :step, :synthesis, :start], [:cyclium, :step, :synthesis]],
      fn event, _measurements, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {episode, {:ok, _}} = run(SlowSynth)
    id = episode.id

    assert_receive {:telemetry, [:cyclium, :step, :synthesis, :start], %{episode_id: ^id}}
    assert_receive {:telemetry, [:cyclium, :step, :synthesis], %{episode_id: ^id}}

    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(
             messages,
             &match?({:telemetry, [:cyclium, :step, :synthesis, :start], _}, &1)
           )
  end
end

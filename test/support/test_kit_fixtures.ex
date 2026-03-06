defmodule Cyclium.TestKit.SampleCheckpointV3 do
  @moduledoc false
  use Cyclium.CheckpointSchema, version: 3

  def migrate(1, state) do
    {:ok, Map.put(state, "format", "v2")}
  end

  def migrate(2, state) do
    {:ok, Map.put(state, "format", "v3")}
  end

  def migrate(3, state), do: {:ok, state}
  def migrate(_v, _state), do: {:error, :unsupported_version}
end

defmodule Cyclium.TestKit.FragileCheckpoint do
  @moduledoc "Checkpoint that crashes on unexpected keys — for testing robustness."
  use Cyclium.CheckpointSchema, version: 2

  def migrate(1, state) do
    # Deliberately fragile — accesses a required key
    case Map.fetch(state, "required_field") do
      {:ok, _} -> {:ok, Map.put(state, "version", 2)}
      :error -> {:error, :missing_required_field}
    end
  end

  def migrate(2, state), do: {:ok, state}
  def migrate(_v, _state), do: {:error, :unsupported_version}
end

defmodule Cyclium.TestKit.SampleStrategy do
  @moduledoc "Minimal strategy that gathers, synthesizes, then converges."
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, _trigger) do
    {:ok, %{"phase" => "gather", "data" => nil, "synthesis" => nil}}
  end

  @impl true
  def next_step(%{"phase" => "gather"}, _ctx) do
    {:tool_call, :test_tool, :fetch_data, %{"query" => "test"}}
  end

  def next_step(%{"phase" => "synthesize"}, _ctx) do
    {:synthesize, %{system: "analyze this", data: "test"}}
  end

  def next_step(%{"phase" => "converge"}, _ctx) do
    :converge
  end

  def next_step(%{"phase" => "done"}, _ctx) do
    :done
  end

  @impl true
  def handle_result(state, _step, result) do
    case state["phase"] do
      "gather" ->
        {:ok, %{state | "data" => result, "phase" => "synthesize"}}

      "synthesize" ->
        {:ok, %{state | "synthesis" => result, "phase" => "converge"}}
    end
  end

  @impl true
  def converge(_state, _ctx) do
    {:ok,
     %Cyclium.ConvergeResult{
       summary: "Test complete",
       findings: [],
       outputs: [],
       classification: %{"type" => "test"},
       confidence: 0.95
     }}
  end
end

defmodule Cyclium.TestKit.InfiniteStrategy do
  @moduledoc "Strategy that never terminates — for testing max_steps guard."
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, _trigger), do: {:ok, %{"counter" => 0}}

  @impl true
  def next_step(_state, _ctx) do
    {:tool_call, :test_tool, :noop, %{}}
  end

  @impl true
  def handle_result(state, _step, _result) do
    {:ok, Map.update!(state, "counter", &(&1 + 1))}
  end

  @impl true
  def converge(_state, _ctx) do
    {:ok, %Cyclium.ConvergeResult{summary: "never reached"}}
  end
end

defmodule Cyclium.TestKit.AbortingStrategy do
  @moduledoc "Strategy that aborts after first step."
  @behaviour Cyclium.EpisodeRunner.Strategy

  @impl true
  def init(_episode, _trigger), do: {:ok, %{"phase" => "check"}}

  @impl true
  def next_step(_state, _ctx), do: {:tool_call, :test_tool, :check, %{}}

  @impl true
  def handle_result(_state, _step, _result), do: {:abort, :test_abort_reason}

  @impl true
  def converge(_state, _ctx) do
    {:ok, %Cyclium.ConvergeResult{summary: "aborted"}}
  end
end

defmodule Cyclium.TestKit.SampleSynthesizer do
  @moduledoc false
  @behaviour Cyclium.Synthesizer

  @impl true
  def synthesize(_prompt_ctx, _episode_ctx) do
    {:ok, %{"response" => "sample synthesis result"}}
  end

  @impl true
  def estimate_tokens(_prompt_ctx), do: 150
end

defmodule Cyclium.TestKit.SampleOutputAdapter do
  @moduledoc false
  @behaviour Cyclium.Output.Adapter

  @impl true
  def deliver(_type, _payload, _ctx) do
    {:ok, %{ref: "sample-ref-#{System.unique_integer([:positive])}"}}
  end
end

defmodule Cyclium.TestKit.SampleActor do
  @moduledoc false
  use Cyclium.Actor

  actor do
    identifier(:test_kit_actor)
    domain(:testing)
    capabilities([:test_tool])
    max_concurrent_episodes(5)
    spec_rev("1.0.0")

    expectation(:health_check,
      trigger: {:schedule, :timer.hours(4)},
      strategy: Cyclium.TestKit.SampleStrategy,
      description: "Test health check",
      budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000},
      recovery_policy: :restart
    )

    expectation(:event_handler,
      trigger: {:event, "test.event_fired"},
      strategy: Cyclium.TestKit.SampleStrategy,
      description: "Test event handler"
    )
  end
end

defmodule Cyclium.TestKit.MinimalActor do
  @moduledoc false
  use Cyclium.Actor

  actor do
    identifier(:minimal_actor)

    expectation(:basic,
      trigger: {:schedule, :timer.minutes(30)},
      strategy: Cyclium.TestKit.SampleStrategy
    )
  end
end

defmodule Cyclium.TestKit.SampleWorkflow do
  @moduledoc false
  use Cyclium.Workflow

  workflow do
    trigger({:event, "test.workflow_trigger"})
    subject_key(:entity_id)

    step(:gather,
      actor: Cyclium.TestKit.SampleActor,
      expectation: :health_check,
      input: fn trigger, _prior -> %{entity_id: trigger["entity_id"]} end
    )

    step(:analyze,
      actor: Cyclium.TestKit.SampleActor,
      expectation: :event_handler,
      depends_on: [:gather],
      input: fn _trigger, prior -> %{gathered: prior[:gather]} end
    )

    on_failure(:gather, :abort)
    on_failure(:analyze, :retry, max_step_attempts: 3, backoff_ms: 1_000)
  end
end

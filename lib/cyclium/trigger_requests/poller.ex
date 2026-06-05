defmodule Cyclium.TriggerRequests.Poller do
  @moduledoc """
  Polls `cyclium_trigger_requests` for pending rows and dispatches them
  to `Runner.OTP` for local execution.

  Always started as part of the supervisor tree, but only polls when the
  node-wide mode is `:full`. This allows runtime mode switches to
  activate/deactivate polling without restarting processes.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.minutes(1)
  @default_batch_size 10
  @stale_expiry_seconds 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, default_interval())
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    source_stack = Keyword.get(opts, :source_stack)
    # Defaults to this node's env so a full node only claims its own env's
    # deferred requests (strict equality). Override via :trigger_poll_source_env.
    source_env = Keyword.get(opts, :source_env, Cyclium.Env.current())

    state = %{
      interval: interval,
      batch_size: batch_size,
      source_stack: source_stack,
      source_env: source_env
    }

    schedule_poll(interval)

    Logger.info(
      "TriggerRequests.Poller started (interval=#{interval}ms, " <>
        "stack=#{inspect(source_stack)}, env=#{inspect(source_env)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    if Cyclium.Mode.current() == :full do
      poll(state)
    end

    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp poll(state) do
    node_name = Cyclium.NodeIdentity.name()

    # source_env is always passed (including nil → default env) so env scoping
    # is never silently dropped; source_stack stays opt-in (nil = any stack).
    fetch_opts =
      [limit: state.batch_size, source_env: state.source_env] ++
        if(state.source_stack, do: [source_stack: state.source_stack], else: [])

    {:ok, requests} = Cyclium.TriggerRequests.fetch_pending(fetch_opts)

    if requests != [] do
      Logger.info("Found #{length(requests)} pending trigger request(s)")
      Enum.each(requests, &dispatch(&1, node_name))
    end

    # Periodically expire stale requests — scoped to this poller's env so it
    # never GCs another env's pending requests (mirrors fetch_pending).
    Cyclium.TriggerRequests.expire_stale(@stale_expiry_seconds, source_env: state.source_env)
  end

  defp dispatch(request, node_name) do
    dedupe_key = "trigger_request:#{request.id}"

    case Cyclium.WorkClaims.gate_acquire(dedupe_key, node_name, work_type: "trigger_request") do
      {:ok, :passthrough} ->
        do_dispatch(request, node_name, nil)

      {:ok, _claim} ->
        do_dispatch(request, node_name, dedupe_key)

      {:error, :busy} ->
        :ok
    end
  end

  defp do_dispatch(request, node_name, dedupe_key) do
    Cyclium.TriggerRequests.mark_claimed(request.id, node_name)

    opts =
      case request.opts do
        %{"resume" => true} -> [resume: true]
        _ -> []
      end

    case Cyclium.Runner.OTP.enqueue(request.episode_id, opts) do
      {:ok, _} ->
        Cyclium.TriggerRequests.mark_completed(request.id)
        Cyclium.WorkClaims.gate_complete(dedupe_key, node_name)

      {:error, reason} ->
        Logger.warning("Failed to dispatch trigger request #{request.id}: #{inspect(reason)}",
          cyclium_episode_id: request.episode_id
        )

        Cyclium.TriggerRequests.mark_expired(request.id)
        Cyclium.WorkClaims.gate_fail(dedupe_key, node_name, %{reason: inspect(reason)})
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp default_interval do
    Application.get_env(:cyclium, :trigger_poll_interval_ms, @default_interval_ms)
  end
end

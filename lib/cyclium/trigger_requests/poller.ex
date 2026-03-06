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

    state = %{
      interval: interval,
      batch_size: batch_size,
      source_stack: source_stack
    }

    schedule_poll(interval)

    Logger.info(
      "TriggerRequests.Poller started (interval=#{interval}ms, stack=#{inspect(source_stack)})"
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

    claim_opts =
      [limit: state.batch_size] ++
        if(state.source_stack, do: [source_stack: state.source_stack], else: [])

    {:ok, requests} = Cyclium.TriggerRequests.claim_pending(node_name, claim_opts)

    if requests != [] do
      Logger.info("Claimed #{length(requests)} trigger request(s)")
      Enum.each(requests, &dispatch/1)
    end

    # Periodically expire stale requests
    Cyclium.TriggerRequests.expire_stale(@stale_expiry_seconds)
  end

  defp dispatch(request) do
    opts =
      case request.opts do
        %{"resume" => true} -> [resume: true]
        _ -> []
      end

    case Cyclium.Runner.OTP.enqueue(request.episode_id, opts) do
      {:ok, _} ->
        Cyclium.TriggerRequests.mark_completed(request.id)

      {:error, reason} ->
        Logger.warning("Failed to dispatch trigger request #{request.id}: #{inspect(reason)}",
          cyclium_episode_id: request.episode_id
        )

        Cyclium.TriggerRequests.mark_expired(request.id)
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp default_interval do
    Application.get_env(:cyclium, :trigger_poll_interval_ms, @default_interval_ms)
  end
end

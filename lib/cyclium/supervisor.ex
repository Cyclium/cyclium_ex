defmodule Cyclium.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if pubsub = Keyword.get(opts, :pubsub) do
      Application.put_env(:cyclium, :pubsub, pubsub)
    end

    Cyclium.CircuitBreaker.ensure_table()
    Cyclium.ServiceLevels.ensure_table()
    Cyclium.AdaptiveBudget.ensure_table()
    Cyclium.Findings.Config.ensure_table()
    Cyclium.ToolCache.ensure_table()
    Cyclium.ActorCapacity.ensure_table()

    children =
      [
        Cyclium.Mode,
        # Sweeps expired tool-result cache entries; the table itself is created
        # above so it outlives a restart of this process.
        Cyclium.ToolCache,
        # Per-node actor process registry, keyed by actor_id string. Lets recovery
        # (and anything else) find a live actor's pid by id regardless of the
        # `name:` it was started under or which supervisor owns it. Compiled and
        # dynamic actors both register here from `Actor.Server.init_state_from_config/3`.
        {Registry, keys: :unique, name: Cyclium.ActorProcessRegistry},
        {DynamicSupervisor, name: Cyclium.ActorSupervisor, strategy: :one_for_one},
        # Running episode tasks, keyed by episode id, for the drainer below.
        {Registry, keys: :unique, name: Cyclium.EpisodeProcessRegistry},
        {DynamicSupervisor, name: Cyclium.EpisodeSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Cyclium.TaskSupervisor},
        # AFTER EpisodeSupervisor on purpose: children stop in reverse start
        # order, so on shutdown the drainer hands every running episode to
        # recovery in one pass while the tasks are still alive to be told.
        Cyclium.EpisodeDrainer
      ] ++ optional_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  # Public for tests: the children that depend on configuration.
  def optional_children do
    reconciler =
      if Application.get_env(:cyclium, :reconciler, false) do
        [Cyclium.Reconciler]
      else
        []
      end

    workflow_engine =
      if Application.get_env(:cyclium, :workflows, []) != [] do
        [Cyclium.WorkflowEngine]
      else
        []
      end

    work_claims =
      if Application.get_env(:cyclium, :work_claims) do
        [
          {DynamicSupervisor,
           name: Cyclium.WorkClaims.HeartbeatSupervisor, strategy: :one_for_one}
        ]
      else
        []
      end

    finding_sweep =
      if Application.get_env(:cyclium, :finding_sweep, false) do
        [Cyclium.Findings.FindingSweep]
      else
        []
      end

    # Unset options fall through to the poller's own defaults: the interval to
    # :trigger_poll_interval_ms (5 s), source_env to Cyclium.Env.current()
    # (this node's env). Set :trigger_poll_source_env only to poll a
    # *different* env than the node runs as.
    poller_opts =
      [
        source_stack: Application.get_env(:cyclium, :trigger_poll_source_stack),
        source_env: Application.get_env(:cyclium, :trigger_poll_source_env)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    trigger_poller =
      if Application.get_env(:cyclium, :trigger_poller, true) do
        [{Cyclium.TriggerRequests.Poller, poller_opts}]
      else
        []
      end

    reconciler ++ workflow_engine ++ work_claims ++ finding_sweep ++ trigger_poller
  end
end

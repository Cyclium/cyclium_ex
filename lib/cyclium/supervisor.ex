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

    children =
      [
        {DynamicSupervisor, name: Cyclium.ActorSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Cyclium.EpisodeSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Cyclium.TaskSupervisor}
      ] ++ optional_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp optional_children do
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

    reconciler ++ workflow_engine ++ work_claims
  end
end

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

    children = [
      {Task.Supervisor, name: Cyclium.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

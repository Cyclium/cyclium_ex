defmodule Cyclium.FakeRunner do
  @moduledoc """
  Fake runner for workflow engine tests. Records enqueue calls
  without actually running episodes.
  """

  @behaviour Cyclium.Runner

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl true
  def enqueue(episode_id, _opts \\ []) do
    Agent.update(__MODULE__, fn calls -> [episode_id | calls] end)
    {:ok, :fake_pid}
  end

  @impl true
  def recover_incomplete, do: :ok

  @impl true
  def cancel(_episode_id), do: :ok

  def enqueued_episodes do
    Agent.get(__MODULE__, & &1)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end

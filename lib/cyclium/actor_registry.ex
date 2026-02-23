defmodule Cyclium.ActorRegistry do
  @moduledoc """
  Convenience functions for starting and managing actor GenServers
  under the Cyclium.ActorSupervisor.
  """

  @doc """
  Start an actor GenServer under the ActorSupervisor.
  """
  def start_actor(module, opts \\ []) do
    DynamicSupervisor.start_child(Cyclium.ActorSupervisor, {module, opts})
  end

  @doc """
  Stop an actor GenServer.
  """
  def stop_actor(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(Cyclium.ActorSupervisor, pid)
  end

  @doc """
  List all running actor PIDs.
  """
  def list_actors do
    DynamicSupervisor.which_children(Cyclium.ActorSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

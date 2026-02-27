defmodule Cyclium.DynamicActor do
  @moduledoc """
  Generic actor module for DB-defined agents.

  Unlike compiled actors that use `use Cyclium.Actor` with DSL macros,
  DynamicActor is a single GenServer module that can serve any number
  of actor instances. Each instance is differentiated by its init args
  (config map and expectations list).

  ## Starting a dynamic actor

      DynamicSupervisor.start_child(Cyclium.ActorSupervisor, {
        Cyclium.DynamicActor,
        name: :my_dynamic_actor,
        config: %{actor_id: :my_actor, domain: :monitoring, ...},
        expectations: [{:check_health, [trigger: {:schedule, 60_000}, ...]}]
      })

  ## How it works

  DynamicActor delegates all GenServer callbacks to `Cyclium.Actor.Server`,
  which is the same module that handles compiled actors. The only difference
  is that config and expectations come from init args rather than compiled
  module attributes.
  """

  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: {:global, name})
  end

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    expectations = Keyword.fetch!(opts, :expectations)

    # Ensure config has the required shape
    config =
      if is_map(config) and not Map.has_key?(config, :max_concurrent_episodes) do
        Map.merge(
          %{
            max_concurrent_episodes: 5,
            episode_overflow: :queue,
            synthesizer: nil
          },
          config
        )
      else
        config
      end

    Cyclium.Actor.Server.init_state_from_config(config, expectations)
  end

  @impl true
  def handle_info(msg, state) do
    Cyclium.Actor.Server.handle_info(msg, state)
  end

  @impl true
  def handle_call(:active_episode_count, _from, state) do
    {:reply, MapSet.size(state.active_episodes), state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:enter_drain, state) do
    {:noreply, Cyclium.Actor.Server.enter_drain(state)}
  end

  def handle_cast(msg, state) do
    Cyclium.Actor.Server.handle_cast(msg, state)
  end
end

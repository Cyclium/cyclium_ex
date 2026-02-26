defmodule Cyclium.Actor do
  @moduledoc """
  Macro and GenServer for Cyclium actors.

  ## Usage

      defmodule MyApp.Agents.POStatus do
        use Cyclium.Actor

        actor do
          domain :procurement
          synthesizer MyApp.Synthesizers.Procurement
          capabilities [:erp_read, :vendor_read, :email_write]

          max_concurrent_episodes 3
          episode_overflow :queue

          expectation :po_delivery_sla,
            trigger: {:schedule, :timer.hours(4)},
            description: "Open POs should have confirmed ETA within SLA",
            outputs: [:email, :slack],
            budget: %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}

          expectation :po_stalled,
            trigger: {:event, "po.status_changed"},
            filter: %{new_status: "STALLED"},
            description: "Stalled POs get triaged",
            outputs: [:email, :slack, :issue]
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer

      import Cyclium.Actor.DSL

      Module.register_attribute(__MODULE__, :cyclium_domain, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_synthesizer, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_capabilities, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_max_concurrent, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_overflow, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_expectations, accumulate: true)

      @before_compile Cyclium.Actor

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent
        }
      end

      @impl true
      def init(opts) do
        Cyclium.Actor.Server.init_state(__MODULE__, opts)
      end

      @impl true
      def handle_info(msg, state) do
        Cyclium.Actor.Server.handle_info(msg, state)
      end

      @impl true
      def handle_cast(msg, state) do
        Cyclium.Actor.Server.handle_cast(msg, state)
      end

      defoverridable child_spec: 1, init: 1, handle_info: 2, handle_cast: 2
    end
  end

  defmacro __before_compile__(env) do
    domain = Module.get_attribute(env.module, :cyclium_domain) || :default
    synthesizer = Module.get_attribute(env.module, :cyclium_synthesizer)
    capabilities = Module.get_attribute(env.module, :cyclium_capabilities) || []
    max_concurrent = Module.get_attribute(env.module, :cyclium_max_concurrent) || 3
    overflow = Module.get_attribute(env.module, :cyclium_overflow) || :queue
    expectations = Module.get_attribute(env.module, :cyclium_expectations) || []

    actor_id =
      env.module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

    quote do
      def __cyclium_config__ do
        %{
          actor_id: unquote(actor_id),
          domain: unquote(domain),
          synthesizer: unquote(synthesizer),
          capabilities: unquote(capabilities),
          max_concurrent_episodes: unquote(max_concurrent),
          episode_overflow: unquote(overflow)
        }
      end

      def __cyclium_expectations__ do
        unquote(Macro.escape(expectations))
      end
    end
  end
end

defmodule Cyclium.Actor.DSL do
  @moduledoc false

  defmacro actor(do: block) do
    block
  end

  defmacro domain(name) do
    quote do
      @cyclium_domain unquote(name)
    end
  end

  defmacro synthesizer(module) do
    quote do
      @cyclium_synthesizer unquote(module)
    end
  end

  defmacro capabilities(list) do
    quote do
      @cyclium_capabilities unquote(list)
    end
  end

  defmacro max_concurrent_episodes(n) do
    quote do
      @cyclium_max_concurrent unquote(n)
    end
  end

  defmacro episode_overflow(policy) do
    quote do
      @cyclium_overflow unquote(policy)
    end
  end

  defmacro expectation(id, opts) do
    quote do
      @cyclium_expectations {unquote(id), unquote(opts)}
    end
  end
end

defmodule Cyclium.Actor.Server do
  @moduledoc """
  GenServer logic for Cyclium actors. Extracted from the macro to keep
  the Actor module clean and testable.
  """

  require Logger

  alias Cyclium.{Bus, Expectation}

  def init_state(module, _opts) do
    config = module.__cyclium_config__()
    raw_expectations = module.__cyclium_expectations__()

    expectations =
      raw_expectations
      |> Enum.map(fn {id, opts} ->
        {id, build_expectation(id, config, opts)}
      end)
      |> Map.new()

    state = %{
      module: module,
      actor_id: config.actor_id,
      config: config,
      expectations: expectations,
      active_episodes: MapSet.new(),
      queued_episodes: :queue.new(),
      timers: %{},
      debounce_timers: %{},
      cooldowns: %{}
    }

    # Subscribe to bus for event-triggered expectations
    Bus.subscribe()

    # Start schedule timers
    state = start_schedule_timers(state)

    {:ok, state}
  end

  def handle_info({:schedule_fire, expectation_id}, state) do
    state =
      case Map.get(state.expectations, expectation_id) do
        nil ->
          state

        expectation ->
          trigger_ref = %Cyclium.Trigger.Schedule{
            scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          state = maybe_fire_episode(state, expectation, trigger_ref)
          reschedule_timer(state, expectation)
      end

    {:noreply, state}
  end

  def handle_info({:debounce_fire, key, trigger_ref}, state) do
    state = Map.update!(state, :debounce_timers, &Map.delete(&1, key))

    expectation_id =
      case key do
        id when is_atom(id) -> id
        {id, _subject} -> id
      end

    case Map.get(state.expectations, expectation_id) do
      nil -> {:noreply, state}
      expectation -> {:noreply, maybe_fire_episode(state, expectation, trigger_ref)}
    end
  end

  def handle_info({:bus, event_type, payload}, state) do
    :telemetry.execute([:cyclium, :actor, :event_received], %{count: 1}, %{
      actor_id: state.actor_id,
      event_type: event_type
    })

    # Handle episode lifecycle events — free up active_episodes slots
    state =
      if event_type in ["episode.completed", "episode.failed", "episode.canceled"] do
        episode_id = payload[:episode_id] || payload["episode_id"]
        actor_id = payload[:actor_id] || payload["actor_id"]

        if actor_id == to_string(state.actor_id) and episode_id do
          handle_episode_done(state, episode_id)
        else
          state
        end
      else
        state
      end

    # Match expectations that subscribe to this event
    state =
      state.expectations
      |> Enum.filter(fn {_id, exp} -> event_matches?(exp, event_type, payload) end)
      |> Enum.reduce(state, fn {_id, expectation}, acc ->
        trigger_ref = %Cyclium.Trigger.Event{
          event_id: payload[:event_id] || Ecto.UUID.generate(),
          event_type: event_type,
          entity_id: payload[:entity_id],
          payload: payload
        }

        handle_event_trigger(acc, expectation, trigger_ref)
      end)

    {:noreply, state}
  end

  def handle_info({:episode_completed, episode_id}, state) do
    {:noreply, handle_episode_done(state, episode_id)}
  end

  def handle_info({:episode_failed, episode_id}, state) do
    {:noreply, handle_episode_done(state, episode_id)}
  end

  # Task process exit — the linked Task finished (normal or crash)
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast({:reconcile, new_config, new_expectations}, state) do
    {:noreply, reconcile_state(state, new_config, new_expectations)}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  # --- Reconciliation ---

  defp reconcile_state(state, new_config, raw_expectations) do
    new_expectations =
      raw_expectations
      |> Enum.map(fn {id, opts} -> {id, build_expectation(id, new_config, opts)} end)
      |> Map.new()

    old_ids = Map.keys(state.expectations) |> MapSet.new()
    new_ids = Map.keys(new_expectations) |> MapSet.new()

    removed = MapSet.difference(old_ids, new_ids)
    added = MapSet.difference(new_ids, old_ids)

    # Cancel timers for removed expectations
    removed_list = MapSet.to_list(removed)

    state =
      Enum.reduce(removed_list, state, fn id, acc ->
        acc = cancel_timer(acc, id)
        cancel_debounce_for_expectation(acc, id)
      end)

    # Drop cooldowns for removed expectations (both atom and {atom, subject} keys)
    cooldowns =
      Map.reject(state.cooldowns, fn {key, _} ->
        case key do
          id when is_atom(id) -> id in removed_list
          {id, _subject} -> id in removed_list
          _ -> false
        end
      end)

    # Update state with new config and expectations
    state = %{
      state
      | config: new_config,
        expectations: new_expectations,
        cooldowns: cooldowns
    }

    # Start timers for newly added schedule expectations
    Enum.reduce(added, state, fn id, acc ->
      case Map.get(new_expectations, id) do
        %{trigger: {:schedule, interval_ms}} when is_integer(interval_ms) ->
          ref = Process.send_after(self(), {:schedule_fire, id}, interval_ms)
          put_in(acc.timers[id], ref)

        _ ->
          acc
      end
    end)
  end

  defp cancel_timer(state, expectation_id) do
    case Map.get(state.timers, expectation_id) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        %{state | timers: Map.delete(state.timers, expectation_id)}
    end
  end

  # --- Private ---

  defp build_expectation(id, config, opts) do
    %Expectation{
      id: id,
      actor_id: config.actor_id,
      domain: config.domain,
      trigger: Keyword.get(opts, :trigger),
      subscribes_to: Keyword.get(opts, :subscribes_to, infer_subscriptions(opts)),
      filter: Keyword.get(opts, :filter, %{}),
      debounce_ms: Keyword.get(opts, :debounce_ms),
      cooldown_ms: Keyword.get(opts, :cooldown_ms),
      subject_key: Keyword.get(opts, :subject_key),
      resources: Keyword.get(opts, :resources, []),
      outputs: Keyword.get(opts, :outputs, []),
      budget:
        Keyword.get(opts, :budget, %{max_turns: 12, max_tokens: 25_000, max_wall_ms: 120_000}),
      log_strategy: Keyword.get(opts, :log_strategy, :timeline),
      audit_level: Keyword.get(opts, :audit_level, :standard),
      retention_days: Keyword.get(opts, :retention_days, 90),
      description: Keyword.get(opts, :description, ""),
      synthesizer: Keyword.get(opts, :synthesizer) || config.synthesizer,
      recovery_policy: Keyword.get(opts, :recovery_policy, :fail)
    }
  end

  # Infer subscribes_to from event triggers
  defp infer_subscriptions(opts) do
    case Keyword.get(opts, :trigger) do
      {:event, event_type} when is_binary(event_type) -> [event_type]
      _ -> []
    end
  end

  defp start_schedule_timers(state) do
    state.expectations
    |> Enum.reduce(state, fn {_id, expectation}, acc ->
      case expectation.trigger do
        {:schedule, interval_ms} when is_integer(interval_ms) ->
          delay = compute_schedule_delay(state.actor_id, expectation.id, interval_ms)
          ref = Process.send_after(self(), {:schedule_fire, expectation.id}, delay)
          put_in(acc.timers[expectation.id], ref)

        _ ->
          acc
      end
    end)
  end

  @min_startup_delay_ms :timer.seconds(10)
  @max_startup_delay_ms :timer.minutes(5)

  defp compute_schedule_delay(actor_id, expectation_id, interval_ms) do
    case Cyclium.Episodes.last_schedule_fire(actor_id, expectation_id) do
      nil ->
        jittered_startup_delay()

      last_fired_at ->
        elapsed_ms = DateTime.diff(DateTime.utc_now(), last_fired_at, :millisecond)
        remaining = interval_ms - elapsed_ms

        if remaining <= 0 do
          jittered_startup_delay()
        else
          remaining
        end
    end
  rescue
    error ->
      Logger.warning(
        "Cyclium.Actor: #{actor_id}/#{expectation_id} schedule lookup failed: #{inspect(error)}, falling back to interval=#{interval_ms}ms"
      )

      interval_ms
  end

  defp jittered_startup_delay do
    Enum.random(@min_startup_delay_ms..@max_startup_delay_ms)
  end

  defp reschedule_timer(state, expectation) do
    case expectation.trigger do
      {:schedule, interval_ms} when is_integer(interval_ms) ->
        ref = Process.send_after(self(), {:schedule_fire, expectation.id}, interval_ms)
        put_in(state.timers[expectation.id], ref)

      _ ->
        state
    end
  end

  defp event_matches?(expectation, event_type, payload) do
    event_type in expectation.subscribes_to and filter_matches?(expectation.filter, payload)
  end

  defp filter_matches?(filter, _payload) when filter == %{}, do: true

  defp filter_matches?(filter, payload) when is_map(filter) do
    Enum.all?(filter, fn {key, expected} ->
      actual = Map.get(payload, key) || Map.get(payload, to_string(key))

      case expected do
        {:in, values} -> actual in values
        value -> actual == value
      end
    end)
  end

  defp subject_scoped_key(expectation, trigger_ref) do
    case expectation.subject_key do
      nil ->
        expectation.id

      key when is_atom(key) ->
        value =
          case trigger_ref do
            %Cyclium.Trigger.Event{payload: p} ->
              Map.get(p, key) || Map.get(p, to_string(key))

            _ ->
              nil
          end

        {expectation.id, value}
    end
  end

  defp handle_event_trigger(state, expectation, trigger_ref) do
    key = subject_scoped_key(expectation, trigger_ref)

    if in_cooldown?(state, key) do
      state
    else
      case expectation.debounce_ms do
        nil ->
          maybe_fire_episode(state, expectation, trigger_ref)

        ms when is_integer(ms) and ms > 0 ->
          # Cancel existing debounce timer
          state = cancel_debounce(state, key)
          ref = Process.send_after(self(), {:debounce_fire, key, trigger_ref}, ms)
          put_in(state.debounce_timers[key], ref)

        _ ->
          maybe_fire_episode(state, expectation, trigger_ref)
      end
    end
  end

  defp in_cooldown?(state, key) do
    case Map.get(state.cooldowns, key) do
      nil -> false
      expiry -> DateTime.compare(DateTime.utc_now(), expiry) == :lt
    end
  end

  defp cancel_debounce_for_expectation(state, expectation_id) do
    {to_cancel, remaining} =
      Enum.split_with(state.debounce_timers, fn {key, _ref} ->
        key == expectation_id or match?({^expectation_id, _}, key)
      end)

    Enum.each(to_cancel, fn {_key, ref} -> Process.cancel_timer(ref) end)
    %{state | debounce_timers: Map.new(remaining)}
  end

  defp cancel_debounce(state, key) do
    case Map.get(state.debounce_timers, key) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.update!(state, :debounce_timers, &Map.delete(&1, key))
    end
  end

  defp maybe_fire_episode(state, expectation, trigger_ref) do
    active_count = MapSet.size(state.active_episodes)
    max = state.config.max_concurrent_episodes

    # Set cooldown
    state = set_cooldown(state, expectation, trigger_ref)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    episode_params = %{
      actor_id: to_string(state.actor_id),
      expectation_id: to_string(expectation.id),
      trigger_type: trigger_type_atom(trigger_ref),
      trigger_ref: trigger_ref_to_map(trigger_ref),
      dedupe_key: generate_dedupe_key(state.actor_id, expectation.id, trigger_ref),
      status: :running,
      budget: normalize_budget(expectation.budget),
      log_strategy: to_string(expectation.log_strategy),
      started_at: now
    }

    # Jitter to distribute episode creation across cluster nodes
    Process.sleep(:rand.uniform(200))

    cond do
      active_count < max ->
        enqueue_episode(state, episode_params)

      state.config.episode_overflow == :queue ->
        queue_episode(state, episode_params, now)

      state.config.episode_overflow == :drop ->
        drop_episode(state, episode_params)

      state.config.episode_overflow == :shed_oldest ->
        shed_and_enqueue(state, episode_params)

      true ->
        state
    end
  end

  defp enqueue_episode(state, params) do
    case Cyclium.Episodes.create(params) do
      {:ok, episode} ->
        runner().enqueue(episode.id)

        Bus.broadcast("expectation.triggered", %{
          actor_id: state.actor_id,
          expectation_id: params.expectation_id,
          episode_id: episode.id
        })

        Map.update!(state, :active_episodes, &MapSet.put(&1, episode.id))

      {:error, %Ecto.Changeset{} = cs} ->
        if has_dedupe_violation?(cs) do
          Logger.debug("[#{state.actor_id}] Dedupe skip: #{params.dedupe_key}")
        else
          Logger.warning("[#{state.actor_id}] Episode create failed: #{inspect(cs.errors)}")
        end

        state

      {:error, _} ->
        state
    end
  end

  defp queue_episode(state, params, now) do
    queued_params = Map.put(params, :queued_at, now)

    case Cyclium.Episodes.create(queued_params) do
      {:ok, episode} ->
        Bus.broadcast("episode.queued", %{
          episode_id: episode.id,
          actor_id: state.actor_id,
          expectation_id: params.expectation_id
        })

        Map.update!(state, :queued_episodes, &:queue.in(episode.id, &1))

      {:error, %Ecto.Changeset{} = cs} ->
        if has_dedupe_violation?(cs) do
          Logger.debug("[#{state.actor_id}] Dedupe skip (queued): #{params.dedupe_key}")
        end

        state

      {:error, _} ->
        state
    end
  end

  defp drop_episode(state, params) do
    :telemetry.execute([:cyclium, :actor, :overflow], %{count: 1}, %{
      actor_id: state.actor_id,
      policy: :drop,
      expectation_id: params.expectation_id
    })

    :telemetry.execute([:cyclium, :episode, :dropped], %{count: 1}, %{
      actor_id: state.actor_id,
      expectation_id: params.expectation_id
    })

    Bus.broadcast("episode.dropped", %{
      actor_id: state.actor_id,
      expectation_id: params.expectation_id
    })

    state
  end

  defp shed_and_enqueue(state, params) do
    case :queue.out(state.queued_episodes) do
      {{:value, oldest_id}, rest} ->
        Cyclium.Episodes.update_status(oldest_id, :canceled)

        Bus.broadcast("episode.canceled", %{
          episode_id: oldest_id,
          actor_id: state.actor_id,
          reason: :shed_oldest
        })

        state = %{state | queued_episodes: rest}
        enqueue_episode(state, params)

      {:empty, _} ->
        # Nothing queued to shed — just enqueue directly
        enqueue_episode(state, params)
    end
  end

  defp handle_episode_done(state, episode_id) do
    state = Map.update!(state, :active_episodes, &MapSet.delete(&1, episode_id))

    case :queue.out(state.queued_episodes) do
      {{:value, queued_id}, rest} ->
        runner().enqueue(queued_id)

        state
        |> Map.put(:queued_episodes, rest)
        |> Map.update!(:active_episodes, &MapSet.put(&1, queued_id))

      {:empty, _} ->
        state
    end
  end

  defp set_cooldown(state, expectation, trigger_ref) do
    case expectation.cooldown_ms do
      nil ->
        state

      0 ->
        state

      ms when is_integer(ms) ->
        key = subject_scoped_key(expectation, trigger_ref)
        expiry = DateTime.add(DateTime.utc_now(), ms, :millisecond)
        put_in(state.cooldowns[key], expiry)
    end
  end

  defp trigger_type_atom(%Cyclium.Trigger.Schedule{}), do: :schedule
  defp trigger_type_atom(%Cyclium.Trigger.Event{}), do: :event
  defp trigger_type_atom(%Cyclium.Trigger.Drift{}), do: :drift
  defp trigger_type_atom(%Cyclium.Trigger.Manual{}), do: :manual
  defp trigger_type_atom(%Cyclium.Trigger.Workflow{}), do: :workflow

  defp trigger_ref_to_map(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_budget(budget) when is_map(budget) do
    Map.new(budget, fn {k, v} -> {to_string(k), v} end)
  end

  defp generate_dedupe_key(actor_id, expectation_id, %Cyclium.Trigger.Schedule{} = trigger) do
    # Window bucket = date for daily schedules
    date =
      case trigger.scheduled_at do
        %DateTime{} = dt -> Date.to_iso8601(DateTime.to_date(dt))
        _ -> Date.to_iso8601(Date.utc_today())
      end

    "schedule:#{actor_id}:#{expectation_id}:#{date}"
  end

  defp generate_dedupe_key(actor_id, expectation_id, trigger_ref) do
    hash = :erlang.phash2(trigger_ref_to_map(trigger_ref))
    "event:#{actor_id}:#{expectation_id}:#{hash}"
  end

  defp has_dedupe_violation?(changeset) do
    changeset.errors
    |> Keyword.get_values(:dedupe_key)
    |> Enum.any?(fn {_msg, opts} -> opts[:constraint] == :unique end)
  end

  defp runner do
    Application.get_env(:cyclium, :runner, Cyclium.Runner.OTP)
  end
end

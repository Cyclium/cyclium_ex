defmodule Cyclium.Actor do
  @moduledoc """
  Macro and GenServer for Cyclium actors.

  ## Usage

      defmodule MyApp.Agents.POStatus do
        use Cyclium.Actor

        actor do
          identifier :po_status
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
      Module.register_attribute(__MODULE__, :cyclium_identifier, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_tools, accumulate: false)
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
    tools = Module.get_attribute(env.module, :cyclium_tools) || %{}
    max_concurrent = Module.get_attribute(env.module, :cyclium_max_concurrent) || 3
    overflow = Module.get_attribute(env.module, :cyclium_overflow) || :queue
    expectations = Module.get_attribute(env.module, :cyclium_expectations) || []
    spec_rev = Module.get_attribute(env.module, :cyclium_spec_rev)

    actor_id =
      Module.get_attribute(env.module, :cyclium_identifier) ||
        env.module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

    quote do
      def __cyclium_config__ do
        %{
          actor_id: unquote(actor_id),
          domain: unquote(domain),
          synthesizer: unquote(synthesizer),
          capabilities: unquote(capabilities),
          tools: unquote(Macro.escape(tools)),
          max_concurrent_episodes: unquote(max_concurrent),
          episode_overflow: unquote(overflow),
          spec_rev: unquote(spec_rev)
        }
      end

      def __cyclium_expectations__ do
        unquote(Macro.escape(expectations))
      end

      def identifier do
        unquote(actor_id)
      end
    end
  end
end

defmodule Cyclium.Actor.DSL do
  @moduledoc false

  defmacro actor(do: block) do
    block
  end

  defmacro identifier(id) do
    quote do
      @cyclium_identifier unquote(id)
    end
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

  defmacro spec_rev(rev) do
    quote do
      @cyclium_spec_rev unquote(rev)
    end
  end

  defmacro tools(mapping) do
    quote do
      @cyclium_tools unquote(mapping)
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
    init_state_from_config(config, raw_expectations, module)
  end

  @doc """
  Initializes actor state from a config map and raw expectations list.

  Used by DynamicActor to start actors from DB-defined configurations
  without requiring a compiled actor module.

  `raw_expectations` can be `{id, opts_keyword_list}` tuples (same as from the DSL)
  or `%Expectation{}` structs.
  """
  def init_state_from_config(config, raw_expectations, module \\ nil) do
    expectations =
      raw_expectations
      |> Enum.map(fn
        {id, opts} when is_list(opts) -> {id, build_expectation(id, config, opts)}
        {id, %Expectation{} = exp} -> {id, exp}
        %Expectation{id: id} = exp -> {id, exp}
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
      cooldowns: %{},
      draining: false
    }

    # Set structured logging context for this actor process
    Logger.metadata(
      cyclium_actor_id: config.actor_id,
      cyclium_domain: config[:domain]
    )

    # Register synthesizer so EpisodeTask can resolve it without manual config.
    # Works for both compiled actors (synthesizer from DSL) and dynamic actors
    # (synthesizer from DB config). nil is stored intentionally — it means "use fallback".
    if synthesizer = config[:synthesizer] do
      case synthesizer do
        {mod, opts} when is_atom(mod) and is_list(opts) ->
          :persistent_term.put({:cyclium_actor_synthesizer, config.actor_id}, mod)

          if llm = Keyword.get(opts, :llm) do
            :persistent_term.put({:cyclium_interactive_llm, config.actor_id}, llm)
          end

        mod when is_atom(mod) ->
          :persistent_term.put({:cyclium_actor_synthesizer, config.actor_id}, mod)
      end
    end

    if config[:spec_rev] do
      :persistent_term.put({:cyclium_actor_spec_rev, config.actor_id}, config[:spec_rev])
    end

    # Register tool mappings (capability atom → tool module) so ToolExec
    # can resolve them without a separate capability registry module.
    if tools = config[:tools] do
      Enum.each(tools, fn {capability, tool_module} ->
        :persistent_term.put({:cyclium_tool, config.actor_id, capability}, tool_module)
      end)
    end

    # Register per-expectation strategy and service level configs so EpisodeTask
    # can resolve them without a manually maintained strategy registry.
    Enum.each(expectations, fn {_id, exp} ->
      if exp.strategy do
        :persistent_term.put({:cyclium_actor_strategy, config.actor_id, exp.id}, exp.strategy)
      end

      if exp.synthesizer do
        :persistent_term.put(
          {:cyclium_expectation_synthesizer, config.actor_id, exp.id},
          exp.synthesizer
        )
      end

      if exp.budget do
        :persistent_term.put({:cyclium_expectation_budget, config.actor_id, exp.id}, exp.budget)
      end

      if exp.log_strategy do
        :persistent_term.put(
          {:cyclium_expectation_log_strategy, config.actor_id, exp.id},
          exp.log_strategy
        )
      end

      if exp.strategy_config do
        :persistent_term.put(
          {:cyclium_strategy_config, config.actor_id, exp.id},
          normalize_strategy_config(exp.strategy_config)
        )
      end

      if exp.service_levels do
        Cyclium.ServiceLevels.register(config.actor_id, exp.id, exp.service_levels)
      end

      # Register finding configs (enrichment, escalation, TTL)
      finding_config = %{
        enrichment: exp.finding_enrichment,
        escalation_rules: exp.escalation_rules,
        default_ttl_seconds: exp.finding_ttl_seconds
      }

      if finding_config.enrichment || finding_config.escalation_rules ||
           finding_config.default_ttl_seconds do
        Cyclium.Findings.Config.register(config.actor_id, exp.id, finding_config)
      end
    end)

    # Subscribe to bus for event-triggered expectations
    Bus.subscribe()

    # Start schedule timers
    state = start_schedule_timers(state)

    {:ok, state}
  end

  def handle_info({:force_fire, expectation_id}, state) do
    handle_info({:force_fire, expectation_id, []}, state)
  end

  def handle_info({:force_fire, expectation_id, opts}, state) do
    state =
      case Map.get(state.expectations, expectation_id) do
        nil ->
          Logger.warning("Force fire: unknown expectation",
            cyclium_actor_id: state.actor_id,
            cyclium_expectation_id: expectation_id
          )

          state

        expectation ->
          trigger_ref = %Cyclium.Trigger.Manual{
            requested_by: "force_fire",
            reason: "manual:#{System.system_time(:millisecond)}"
          }

          maybe_fire_episode(state, expectation, trigger_ref, [{:force, true} | opts])
      end

    {:noreply, state}
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
          # Update circuit breaker on episode outcome
          maybe_update_circuit_breaker(state, event_type, payload)
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

  # Recovery hand-off: an already-created `:running` episode is being recovered
  # (see `Cyclium.Recovery`). Route it through the actor's concurrency control so
  # a node that wins many recovery claims doesn't bypass `max_concurrent_episodes`
  # and bury itself with a thundering herd of orphaned episodes.
  def handle_info({:recover_episode, episode_id}, state) do
    {:noreply, enqueue_recovered(state, episode_id)}
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

  # --- Drain ---

  @doc """
  Enters drain mode: stops accepting new episodes but lets active ones finish.
  Schedule timers are cancelled. Event triggers are ignored.
  """
  def enter_drain(state) do
    Logger.info("Entering drain mode", cyclium_actor_id: state.actor_id)

    # Cancel all schedule timers
    state =
      Enum.reduce(state.timers, state, fn {id, _ref}, acc ->
        cancel_timer(acc, id)
      end)

    # Cancel all debounce timers
    Enum.each(state.debounce_timers, fn {_key, ref} -> Process.cancel_timer(ref) end)

    %{state | draining: true, debounce_timers: %{}}
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
      strategy: Keyword.get(opts, :strategy),
      synthesizer: Keyword.get(opts, :synthesizer) || config.synthesizer,
      strategy_config: Keyword.get(opts, :strategy_config),
      recovery_policy: Keyword.get(opts, :recovery_policy, :fail),
      window: Keyword.get(opts, :window) || infer_window(opts),
      dry_run: Keyword.get(opts, :dry_run),
      sample_rate: Keyword.get(opts, :sample_rate),
      circuit_breaker: Keyword.get(opts, :circuit_breaker),
      adaptive_budget: Keyword.get(opts, :adaptive_budget, false),
      service_levels: Keyword.get(opts, :service_levels),
      finding_enrichment: Keyword.get(opts, :finding_enrichment),
      escalation_rules: Keyword.get(opts, :escalation_rules),
      finding_ttl_seconds: Keyword.get(opts, :finding_ttl_seconds)
    }
  end

  # Normalize strategy_config from DSL (atom keys) to the string-key format
  # expected by the Interactive template (consistent with DB-loaded JSON).
  defp normalize_strategy_config(config) when is_map(config) do
    Map.new(config, fn
      {k, v} when is_atom(k) -> {to_string(k), normalize_strategy_config_value(v)}
      {k, v} -> {k, normalize_strategy_config_value(v)}
    end)
  end

  defp normalize_strategy_config_value(list) when is_list(list) do
    Enum.map(list, fn
      item when is_map(item) -> normalize_strategy_config(item)
      item -> item
    end)
  end

  defp normalize_strategy_config_value(map) when is_map(map) do
    normalize_strategy_config(map)
  end

  defp normalize_strategy_config_value(val), do: val

  @h24_ms :timer.hours(24)
  @h48_ms :timer.hours(48)
  @w1_ms :timer.hours(168)

  defp infer_window(opts) do
    case Keyword.get(opts, :trigger) do
      {:schedule, ms} when is_integer(ms) and ms < @h24_ms -> :h4
      {:schedule, ms} when is_integer(ms) and ms < @h48_ms -> :h24
      {:schedule, ms} when is_integer(ms) and ms < @w1_ms -> :h48
      {:schedule, _} -> :w1
      triggers when is_list(triggers) -> infer_window_from_list(triggers)
      _ -> nil
    end
  end

  defp infer_window_from_list(triggers) do
    Enum.find_value(triggers, fn
      {:schedule, ms} when is_integer(ms) and ms < @h24_ms -> :h4
      {:schedule, ms} when is_integer(ms) and ms < @h48_ms -> :h24
      {:schedule, ms} when is_integer(ms) and ms < @w1_ms -> :h48
      {:schedule, _} -> :w1
      _ -> nil
    end)
  end

  # Infer subscribes_to from event triggers (supports single or list)
  defp infer_subscriptions(opts) do
    case Keyword.get(opts, :trigger) do
      {:event, event_type} when is_binary(event_type) -> [event_type]
      triggers when is_list(triggers) -> extract_event_types(triggers)
      _ -> []
    end
  end

  defp extract_event_types(triggers) do
    Enum.flat_map(triggers, fn
      {:event, event_type} when is_binary(event_type) -> [event_type]
      _ -> []
    end)
  end

  # Extract schedule trigger from single or list trigger spec
  defp find_schedule({:schedule, ms} = schedule) when is_integer(ms), do: schedule

  defp find_schedule(triggers) when is_list(triggers) do
    Enum.find_value(triggers, fn
      {:schedule, ms} = schedule when is_integer(ms) -> schedule
      _ -> nil
    end)
  end

  defp find_schedule(_), do: nil

  defp merge_dry_run_opts(_expectation_dry_run, _fire_overrides, :live), do: nil

  defp merge_dry_run_opts(expectation_dry_run, fire_overrides, :dry_run) do
    exp_opts = normalize_dry_run_opts(expectation_dry_run)
    fire_opts = normalize_dry_run_opts(fire_overrides)

    case {exp_opts, fire_opts} do
      {nil, nil} -> nil
      {nil, f} -> f
      {e, nil} -> e
      {e, f} -> Map.merge(e, f)
    end
  end

  defp normalize_dry_run_opts(nil), do: nil

  defp normalize_dry_run_opts(opts) when is_list(opts) do
    opts |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
  end

  defp normalize_dry_run_opts(opts) when is_map(opts) do
    opts |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
  end

  defp start_schedule_timers(state) do
    state.expectations
    |> Enum.reduce(state, fn {_id, expectation}, acc ->
      case find_schedule(expectation.trigger) do
        {:schedule, interval_ms} ->
          delay = compute_schedule_delay(state.actor_id, expectation.id, interval_ms)
          ref = Process.send_after(self(), {:schedule_fire, expectation.id}, delay)
          put_in(acc.timers[expectation.id], ref)

        nil ->
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
        "Schedule lookup failed, falling back to interval=#{interval_ms}ms: #{inspect(error)}",
        cyclium_actor_id: actor_id,
        cyclium_expectation_id: expectation_id
      )

      interval_ms
  end

  defp jittered_startup_delay do
    Enum.random(@min_startup_delay_ms..@max_startup_delay_ms)
  end

  defp reschedule_timer(state, expectation) do
    case find_schedule(expectation.trigger) do
      {:schedule, interval_ms} ->
        ref = Process.send_after(self(), {:schedule_fire, expectation.id}, interval_ms)
        put_in(state.timers[expectation.id], ref)

      nil ->
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

  defp maybe_fire_episode(state, expectation, trigger_ref, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    cond do
      # Reject new episodes while draining
      state.draining ->
        Logger.debug("Rejecting episode fire — draining", cyclium_actor_id: state.actor_id)
        state

      # Circuit breaker: skip if open (unless forced)
      not force and circuit_open?(expectation) ->
        state

      # Sampling: skip unless forced
      not force and sampled_out?(expectation) ->
        :telemetry.execute(
          [:cyclium, :episode, :sampled_out],
          %{sample_rate: expectation.sample_rate},
          %{actor_id: state.actor_id, expectation_id: expectation.id}
        )

        state

      true ->
        do_fire_episode(state, expectation, trigger_ref, opts)
    end
  end

  defp maybe_update_circuit_breaker(state, event_type, payload) do
    expectation_id_str = payload[:expectation_id] || payload["expectation_id"]

    if expectation_id_str do
      exp_id =
        try do
          String.to_existing_atom(to_string(expectation_id_str))
        rescue
          _ -> nil
        end

      case exp_id && Map.get(state.expectations, exp_id) do
        %{circuit_breaker: config} when not is_nil(config) ->
          if event_type == "episode.completed" do
            Cyclium.CircuitBreaker.record_success(state.actor_id, exp_id)
          else
            Cyclium.CircuitBreaker.record_failure(state.actor_id, exp_id, config)
          end

        _ ->
          :ok
      end
    end
  end

  defp circuit_open?(%{circuit_breaker: nil}), do: false

  defp circuit_open?(%{circuit_breaker: config} = expectation) do
    case Cyclium.CircuitBreaker.allow?(expectation.actor_id, expectation.id, config) do
      :ok -> false
      {:error, :circuit_open} -> true
    end
  end

  defp sampled_out?(%{sample_rate: nil}), do: false
  defp sampled_out?(%{sample_rate: rate}) when rate >= 1.0, do: false
  defp sampled_out?(%{sample_rate: rate}) when rate <= 0.0, do: true
  defp sampled_out?(%{sample_rate: rate}), do: :rand.uniform() > rate

  defp do_fire_episode(state, expectation, trigger_ref, opts) do
    active_count = MapSet.size(state.active_episodes)
    max = state.config.max_concurrent_episodes

    # Set cooldown
    state = set_cooldown(state, expectation, trigger_ref)

    mode = Keyword.get(opts, :mode, :live)
    fire_overrides = Keyword.get(opts, :overrides)

    # Merge dry_run_opts: fire-time overrides take priority over expectation-level
    dry_run_opts = merge_dry_run_opts(expectation.dry_run, fire_overrides, mode)

    now = DateTime.utc_now()

    episode_params = %{
      actor_id: to_string(state.actor_id),
      expectation_id: to_string(expectation.id),
      trigger_type: trigger_type_atom(trigger_ref),
      trigger_ref: trigger_ref_to_map(trigger_ref),
      dedupe_key: generate_dedupe_key(state.actor_id, expectation, trigger_ref),
      status: :running,
      budget: normalize_budget(expectation.budget),
      log_strategy: to_string(expectation.log_strategy),
      mode: to_string(mode),
      dry_run_opts: dry_run_opts,
      spec_rev: state.config.spec_rev,
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
        runner(state.actor_id).enqueue(episode.id)

        Bus.broadcast("expectation.triggered", %{
          actor_id: state.actor_id,
          expectation_id: params.expectation_id,
          episode_id: episode.id
        })

        Map.update!(state, :active_episodes, &MapSet.put(&1, episode.id))

      {:error, %Ecto.Changeset{} = cs} ->
        if has_dedupe_violation?(cs) do
          Logger.debug("Dedupe skip",
            cyclium_actor_id: state.actor_id,
            dedupe_key: params.dedupe_key
          )
        else
          Logger.warning("Episode create failed: #{inspect(cs.errors)}",
            cyclium_actor_id: state.actor_id
          )
        end

        state

      {:error, _} ->
        state
    end
  end

  # Enqueue an already-created (recovered) episode under the actor's concurrency
  # control. Unlike `enqueue_episode`, the episode row already exists — we only
  # decide whether to run it now or hold it in the in-memory queue. Recovered
  # episodes are always queued (never dropped/shed) when at capacity: they
  # represent real in-flight work, and they drain via `handle_episode_done` as
  # active slots free up.
  defp enqueue_recovered(state, episode_id) do
    cond do
      MapSet.member?(state.active_episodes, episode_id) ->
        # Already tracked (e.g. duplicate hand-off) — leave it be.
        state

      MapSet.size(state.active_episodes) < state.config.max_concurrent_episodes ->
        runner(state.actor_id).enqueue(episode_id)
        Map.update!(state, :active_episodes, &MapSet.put(&1, episode_id))

      true ->
        Map.update!(state, :queued_episodes, &:queue.in(episode_id, &1))
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
          Logger.debug("Dedupe skip (queued)",
            cyclium_actor_id: state.actor_id,
            dedupe_key: params.dedupe_key
          )
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
        runner(state.actor_id).enqueue(queued_id)

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

  defp generate_dedupe_key(actor_id, expectation, %Cyclium.Trigger.Schedule{} = trigger) do
    dt =
      case trigger.scheduled_at do
        %DateTime{} = d -> d
        _ -> DateTime.utc_now()
      end

    bucket =
      case expectation.window do
        nil -> Date.to_iso8601(DateTime.to_date(dt))
        window -> Cyclium.Window.bucket(window, dt)
      end

    "schedule:#{actor_id}:#{expectation.id}:#{bucket}"
  end

  defp generate_dedupe_key(actor_id, expectation, trigger_ref) do
    hash = :erlang.phash2(trigger_ref_to_map(trigger_ref))
    "event:#{actor_id}:#{expectation.id}:#{hash}"
  end

  defp has_dedupe_violation?(changeset) do
    changeset.errors
    |> Keyword.get_values(:dedupe_key)
    |> Enum.any?(fn {_msg, opts} -> opts[:constraint] == :unique end)
  end

  defp runner(actor_id) do
    Cyclium.Mode.runner_for(actor_id)
  end
end

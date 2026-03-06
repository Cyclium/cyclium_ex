defmodule Cyclium.Test.ActorCase do
  @moduledoc """
  Test helpers for validating actor module definitions.

  Smoke-tests that an actor compiles correctly, has valid expectations,
  strategies resolve, and configuration is well-formed.

  ## Usage

      defmodule MyApp.Actors.ProjectHealthActorTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.ActorCase

        test "actor definition is valid" do
          assert_valid_actor(MyApp.Actors.ProjectHealthActor)
        end

        test "all expectations have strategies" do
          assert_strategies_defined(MyApp.Actors.ProjectHealthActor)
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.ActorCase
    end
  end

  @doc """
  Assert that an actor module has a valid definition: config, identifier,
  and at least one expectation.
  """
  defmacro assert_valid_actor(actor_module) do
    quote bind_quoted: [actor_module: actor_module] do
      Cyclium.Test.ActorCase.validate_actor!(actor_module)
    end
  end

  @doc """
  Assert that every expectation on the actor has a strategy declared.
  """
  defmacro assert_strategies_defined(actor_module) do
    quote bind_quoted: [actor_module: actor_module] do
      Cyclium.Test.ActorCase.validate_strategies_defined!(actor_module)
    end
  end

  @doc """
  Assert that every expectation has valid budget configuration.
  """
  defmacro assert_budgets_valid(actor_module) do
    quote bind_quoted: [actor_module: actor_module] do
      Cyclium.Test.ActorCase.validate_budgets!(actor_module)
    end
  end

  @doc """
  Assert that the actor's spec_rev is set. Useful for enforcing version
  tracking across all actors in a project.
  """
  defmacro assert_spec_rev_set(actor_module) do
    quote bind_quoted: [actor_module: actor_module] do
      Cyclium.Test.ActorCase.validate_spec_rev!(actor_module)
    end
  end

  @doc false
  def validate_actor!(actor_module) do
    Code.ensure_loaded!(actor_module)

    unless function_exported?(actor_module, :__cyclium_config__, 0) do
      raise ArgumentError,
        message: "#{inspect(actor_module)} must define __cyclium_config__/0 (use Cyclium.Actor)"
    end

    config = actor_module.__cyclium_config__()

    unless is_atom(config.actor_id) do
      raise ArgumentError, message: "actor_id must be an atom, got: #{inspect(config.actor_id)}"
    end

    unless config.actor_id do
      raise ArgumentError, message: "actor_id must not be nil"
    end

    unless is_integer(config.max_concurrent_episodes) and config.max_concurrent_episodes > 0 do
      raise ArgumentError,
        message: "max_concurrent_episodes must be > 0, got: #{config.max_concurrent_episodes}"
    end

    unless config.episode_overflow in [:queue, :drop, :shed_oldest] do
      raise ArgumentError,
        message:
          "episode_overflow must be :queue, :drop, or :shed_oldest, got: #{inspect(config.episode_overflow)}"
    end

    unless function_exported?(actor_module, :identifier, 0) do
      raise ArgumentError, message: "#{inspect(actor_module)} must define identifier/0"
    end

    id = actor_module.identifier()

    unless is_atom(id) do
      raise ArgumentError, message: "identifier/0 must return an atom, got: #{inspect(id)}"
    end

    unless function_exported?(actor_module, :__cyclium_expectations__, 0) do
      raise ArgumentError,
        message: "#{inspect(actor_module)} must define __cyclium_expectations__/0"
    end

    expectations = actor_module.__cyclium_expectations__()

    unless is_list(expectations) and length(expectations) > 0 do
      raise ArgumentError, message: "Actor must define at least one expectation"
    end

    Enum.each(expectations, fn {exp_id, opts} ->
      validate_expectation!(actor_module, exp_id, opts)
    end)

    :ok
  end

  @doc false
  def validate_strategies_defined!(actor_module) do
    expectations = actor_module.__cyclium_expectations__()

    Enum.each(expectations, fn {exp_id, opts} ->
      strategy = Keyword.get(opts, :strategy)

      unless strategy do
        raise ArgumentError,
          message: "Expectation #{inspect(exp_id)} on #{inspect(actor_module)} has no strategy"
      end

      unless is_atom(strategy) do
        raise ArgumentError,
          message: "Strategy for #{inspect(exp_id)} must be a module, got: #{inspect(strategy)}"
      end
    end)
  end

  @doc false
  def validate_budgets!(actor_module) do
    expectations = actor_module.__cyclium_expectations__()

    Enum.each(expectations, fn {exp_id, opts} ->
      budget = Keyword.get(opts, :budget, %{})

      if max_turns = budget[:max_turns] do
        unless is_integer(max_turns) and max_turns > 0 do
          raise ArgumentError,
            message: "#{inspect(exp_id)}: budget.max_turns must be positive integer"
        end
      end

      if max_tokens = budget[:max_tokens] do
        unless is_integer(max_tokens) and max_tokens > 0 do
          raise ArgumentError,
            message: "#{inspect(exp_id)}: budget.max_tokens must be positive integer"
        end
      end

      if max_wall_ms = budget[:max_wall_ms] do
        unless is_integer(max_wall_ms) and max_wall_ms > 0 do
          raise ArgumentError,
            message: "#{inspect(exp_id)}: budget.max_wall_ms must be positive integer"
        end
      end
    end)
  end

  @doc false
  def validate_spec_rev!(actor_module) do
    config = actor_module.__cyclium_config__()

    unless config.spec_rev do
      raise ArgumentError,
        message: "#{inspect(actor_module)} should declare spec_rev for deployment tracking"
    end
  end

  @doc false
  def validate_expectation!(actor_module, exp_id, opts) do
    unless is_atom(exp_id) do
      raise ArgumentError,
        message:
          "Expectation ID must be an atom, got: #{inspect(exp_id)} on #{inspect(actor_module)}"
    end

    trigger = Keyword.get(opts, :trigger)

    unless trigger do
      raise ArgumentError,
        message:
          "Expectation #{inspect(exp_id)} on #{inspect(actor_module)} must declare a trigger"
    end

    validate_trigger!(actor_module, exp_id, trigger)

    if recovery = Keyword.get(opts, :recovery_policy) do
      unless recovery in [:fail, :restart] do
        raise ArgumentError,
          message:
            "Expectation #{inspect(exp_id)}: recovery_policy must be :fail or :restart, got: #{inspect(recovery)}"
      end
    end

    if sample_rate = Keyword.get(opts, :sample_rate) do
      unless is_number(sample_rate) and sample_rate >= 0.0 and sample_rate <= 1.0 do
        raise ArgumentError,
          message:
            "Expectation #{inspect(exp_id)}: sample_rate must be 0.0..1.0, got: #{inspect(sample_rate)}"
      end
    end
  end

  defp validate_trigger!(_actor, _exp_id, {:schedule, ms}) when is_integer(ms) and ms > 0, do: :ok

  defp validate_trigger!(_actor, _exp_id, {:event, type}) when is_binary(type), do: :ok

  defp validate_trigger!(_actor, _exp_id, triggers) when is_list(triggers) do
    Enum.each(triggers, fn
      {:schedule, ms} when is_integer(ms) and ms > 0 -> :ok
      {:event, type} when is_binary(type) -> :ok
      other -> raise ArgumentError, message: "Invalid trigger in list: #{inspect(other)}"
    end)
  end

  defp validate_trigger!(actor, exp_id, other) do
    raise ArgumentError,
      message:
        "Expectation #{inspect(exp_id)} on #{inspect(actor)} has invalid trigger: #{inspect(other)}"
  end
end

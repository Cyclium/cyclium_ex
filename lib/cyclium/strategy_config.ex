defmodule Cyclium.StrategyConfig do
  @moduledoc """
  Resolves the `strategy_config` an episode runs under.

  Order:

    1. the config registered for the exact `{actor_id, expectation_id}` pair
       (`:persistent_term`, set by the Actor DSL at boot);
    2. the first config registered for the actor under any expectation
       (non-deterministic for a multi-expectation actor; prefer passing the
       expectation id);
    3. the `strategy_config` column of the actor's `cyclium_agent_definitions`
       row, **only** for actors the dynamic loader started on this node.

  Step 3 is gated on purpose. A definition row named after a compiled actor
  must not be able to supply that actor's tool allow-list, system prompt or
  policy; compiled actors get their config from code or nothing.
  """

  import Ecto.Query

  @dynamic_key :cyclium_dynamic_actor

  @spec load(atom() | binary(), atom() | binary() | nil) :: map()
  def load(actor_id, expectation_id \\ nil)

  def load(actor_id, nil), do: load_for_actor(actor_id)

  def load(actor_id, expectation_id) do
    actor_key = safe_to_atom(actor_id)
    exp_key = safe_to_atom(expectation_id)

    case :persistent_term.get({:cyclium_strategy_config, actor_key, exp_key}, nil) do
      config when is_map(config) and config != %{} -> config
      _ -> load_for_actor(actor_id)
    end
  end

  defp load_for_actor(actor_id) do
    actor_key = safe_to_atom(actor_id)

    case find_in_persistent_term(actor_key) do
      config when is_map(config) and config != %{} ->
        config

      _ ->
        if dynamic_actor?(actor_id), do: load_from_db(actor_id), else: %{}
    end
  end

  @doc "Record that the dynamic loader owns `actor_id` on this node."
  @spec mark_dynamic(atom() | binary()) :: :ok
  def mark_dynamic(actor_id) do
    :persistent_term.put({@dynamic_key, to_string(actor_id)}, true)
    :ok
  end

  @doc "Forget that `actor_id` is dynamic (after the loader stops it)."
  @spec unmark_dynamic(atom() | binary()) :: :ok
  def unmark_dynamic(actor_id) do
    :persistent_term.erase({@dynamic_key, to_string(actor_id)})
    :ok
  end

  @doc "Whether the dynamic loader started `actor_id` on this node."
  @spec dynamic_actor?(atom() | binary()) :: boolean()
  def dynamic_actor?(actor_id) do
    :persistent_term.get({@dynamic_key, to_string(actor_id)}, false) == true
  end

  defp find_in_persistent_term(actor_key) do
    :persistent_term.get()
    |> Enum.find_value(fn
      {{:cyclium_strategy_config, ^actor_key, _exp_id}, config} when is_map(config) -> config
      _ -> nil
    end)
  end

  defp load_from_db(actor_id) do
    case Cyclium.repo().one(
           from(d in Cyclium.Schemas.AgentDefinition,
             where: d.actor_id == ^to_string(actor_id),
             select: d.strategy_config
           )
         ) do
      nil ->
        %{}

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end

      config when is_map(config) ->
        config
    end
  rescue
    _ -> %{}
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(val) when is_atom(val), do: val

  defp safe_to_atom(val) when is_binary(val) do
    case Cyclium.AtomGuard.existing_atom(val) do
      {:ok, atom} -> atom
      :error -> val
    end
  end
end

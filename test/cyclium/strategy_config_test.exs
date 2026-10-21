defmodule Cyclium.StrategyConfigTest do
  use Cyclium.DataCase

  alias Cyclium.StrategyConfig
  alias Cyclium.Schemas.AgentDefinition

  # Compile-time atoms so the string ids resolve to them.
  @compiled :strategy_config_compiled_actor
  @dynamic :strategy_config_dynamic_actor
  @exp :chat

  setup do
    on_exit(fn ->
      :persistent_term.erase({:cyclium_strategy_config, @compiled, @exp})
      StrategyConfig.unmark_dynamic(@dynamic)
      StrategyConfig.unmark_dynamic(@compiled)
    end)

    :ok
  end

  defp insert_definition(actor_id, config) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%AgentDefinition{
      actor_id: to_string(actor_id),
      strategy_template: "interactive",
      strategy_config: Jason.encode!(config),
      inserted_at: now,
      updated_at: now
    })
  end

  test "the exact {actor, expectation} registration wins" do
    :persistent_term.put({:cyclium_strategy_config, @compiled, @exp}, %{"role" => "from code"})
    assert StrategyConfig.load(to_string(@compiled), to_string(@exp)) == %{"role" => "from code"}
  end

  test "a definition row named after a compiled actor does not supply its config" do
    insert_definition(@compiled, %{"allowed_tool_signatures" => [%{"name" => "anything"}]})
    assert StrategyConfig.load(to_string(@compiled), to_string(@exp)) == %{}
  end

  test "a dynamic actor reads its definition row" do
    insert_definition(@dynamic, %{"role" => "from db"})
    StrategyConfig.mark_dynamic(@dynamic)
    assert StrategyConfig.load(to_string(@dynamic), "any") == %{"role" => "from db"}

    StrategyConfig.unmark_dynamic(@dynamic)
    assert StrategyConfig.load(to_string(@dynamic), "any") == %{}
  end
end

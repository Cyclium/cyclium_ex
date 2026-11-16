defmodule Cyclium.SupervisorTest do
  use ExUnit.Case, async: false

  alias Cyclium.TriggerRequests.Poller

  setup do
    previous = Application.fetch_env(:cyclium, :trigger_poller)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cyclium, :trigger_poller, value)
        :error -> Application.delete_env(:cyclium, :trigger_poller)
      end
    end)

    :ok
  end

  defp poller_child do
    Enum.find(Cyclium.Supervisor.optional_children(), &match?({Poller, _}, &1))
  end

  test "starts the trigger poller by default, leaving its interval to the poller" do
    Application.delete_env(:cyclium, :trigger_poller)

    assert {Poller, opts} = poller_child()
    refute Keyword.has_key?(opts, :interval_ms)
  end

  test "leaves the trigger poller out when :trigger_poller is false" do
    Application.put_env(:cyclium, :trigger_poller, false)

    assert poller_child() == nil
  end
end

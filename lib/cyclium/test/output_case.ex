defmodule Cyclium.Test.OutputCase do
  @moduledoc """
  Test helpers for verifying output adapter contract compliance and
  a `FakeOutputAdapter` for use in integration tests.

  ## Usage

      defmodule MyApp.Adapters.SlackTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.OutputCase

        test "delivers successfully" do
          payload = %{channel: "#alerts", message: "test"}
          ctx = %{episode_id: Ecto.UUID.generate()}

          assert_valid_deliver(MyApp.Adapters.Slack, :slack, payload, ctx)
        end
      end

  ## FakeOutputAdapter

      setup do
        {:ok, _} = Cyclium.Test.FakeOutputAdapter.start_link()
        :ok
      end

      # After strategy converge delivers outputs:
      deliveries = Cyclium.Test.FakeOutputAdapter.deliveries()
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.OutputCase
    end
  end

  @doc """
  Assert that `adapter.deliver/3` returns a valid response shape.
  """
  defmacro assert_valid_deliver(adapter, type, payload, ctx) do
    quote bind_quoted: [adapter: adapter, type: type, payload: payload, ctx: ctx] do
      result = adapter.deliver(type, payload, ctx)
      Cyclium.Test.OutputCase.validate_deliver_shape!(result)
    end
  end

  @doc false
  def validate_deliver_shape!(result) do
    case result do
      {:ok, ref} when is_map(ref) -> result
      {:error, _reason} -> result
      other -> raise ArgumentError, message: "deliver/3 returned invalid shape: #{inspect(other)}"
    end
  end

  @doc """
  Assert that an adapter is registered for the given type.
  """
  defmacro assert_adapter_registered(type) do
    quote bind_quoted: [type: type] do
      adapter = Cyclium.Output.Adapter.resolve(type)
      refute is_nil(adapter), "No output adapter registered for type #{inspect(type)}"
      adapter
    end
  end
end

defmodule Cyclium.Test.FakeOutputAdapter do
  @moduledoc """
  In-memory fake output adapter for testing. Records deliveries
  and returns configurable responses.

  ## Usage

      setup do
        {:ok, _} = Cyclium.Test.FakeOutputAdapter.start_link()
        :ok
      end
  """

  @behaviour Cyclium.Output.Adapter

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{deliveries: [], response: {:ok, %{ref: "fake"}}} end,
      name: __MODULE__
    )
  end

  @doc "Set the response returned by deliver/3."
  def set_response(response) do
    Agent.update(__MODULE__, &Map.put(&1, :response, response))
  end

  @doc "Set deliver to return an error."
  def set_error(reason) do
    Agent.update(__MODULE__, &Map.put(&1, :response, {:error, reason}))
  end

  @doc "Return all recorded deliveries as `[{type, payload, ctx}]`."
  def deliveries do
    Agent.get(__MODULE__, & &1.deliveries)
  end

  @doc "Reset deliveries and response."
  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{deliveries: [], response: {:ok, %{ref: "fake"}}}
    end)
  end

  @impl true
  def deliver(type, payload, ctx) do
    Agent.get_and_update(__MODULE__, fn state ->
      new_state = Map.update!(state, :deliveries, &[{type, payload, ctx} | &1])
      {state.response, new_state}
    end)
  end
end

defmodule Cyclium.Output.Adapter do
  @moduledoc """
  Behaviour for output delivery adapters (email, Slack, issues, etc.).
  The consuming app provides implementations per output type.

  Adapters are registered via app config:

      config :cyclium, :output_adapters, %{
        email: MyApp.Adapters.Email,
        slack: MyApp.Adapters.Slack
      }
  """

  @callback deliver(type :: atom(), payload :: map(), ctx :: map()) ::
              {:ok, ref :: map()} | {:error, reason :: term()}

  @doc """
  Resolve an output adapter module by type name.
  Returns `nil` if no adapter is registered for the given type.
  """
  def resolve(type) when is_atom(type) do
    adapters = Application.get_env(:cyclium, :output_adapters, %{})
    Map.get(adapters, type) || Map.get(adapters, to_string(type))
  end

  def resolve(type) when is_binary(type) do
    adapters = Application.get_env(:cyclium, :output_adapters, %{})

    atom_key =
      try do
        String.to_existing_atom(type)
      rescue
        ArgumentError -> nil
      end

    (atom_key && Map.get(adapters, atom_key)) || Map.get(adapters, type)
  end

  @doc """
  List all registered output adapter type names.
  """
  def all do
    Application.get_env(:cyclium, :output_adapters, %{}) |> Map.keys()
  end
end

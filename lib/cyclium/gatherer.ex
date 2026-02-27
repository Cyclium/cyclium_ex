defmodule Cyclium.Gatherer do
  @moduledoc """
  Behaviour for data-gathering modules used by strategy templates.

  Gatherers are the bridge between DB-defined dynamic actors and your
  application's data layer. The compiled app implements gatherers and
  registers them by name so dynamic actors can reference them without
  needing Elixir code.

  ## Usage

      defmodule MyApp.Gatherers.ProjectData do
        @behaviour Cyclium.Gatherer

        @impl true
        def gather(trigger_payload, _opts) do
          project_id = trigger_payload["project_id"]
          project = Repo.get!(Project, project_id)
          orders = load_orders(project_id)
          {:ok, %{project: project, orders: orders}}
        end
      end

  Register in your app config:

      config :cyclium, :gatherer_registry, %{
        "project_data" => MyApp.Gatherers.ProjectData,
        "client_metrics" => MyApp.Gatherers.ClientMetrics
      }
  """

  @callback gather(trigger_payload :: map(), opts :: map()) ::
              {:ok, data :: map()} | {:error, reason :: term()}

  @doc """
  Resolves a gatherer module by its registered name.
  Returns `nil` if no gatherer is registered with the given name.
  """
  def resolve(name) when is_binary(name) do
    registry = Application.get_env(:cyclium, :gatherer_registry, %{})
    Map.get(registry, name)
  end
end

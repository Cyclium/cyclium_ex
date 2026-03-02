defmodule Cyclium.DataCase do
  @moduledoc """
  Test case template for tests that need a real database.

  Sets up a sandboxed SQLite connection and configures the cyclium repo
  for the duration of the test. Safe to use with async: false.

  ## Usage

      defmodule Cyclium.MyTest do
        use Cyclium.DataCase

        test "something db-related" do
          episode = insert_episode(%{actor_id: "my_actor"})
          ...
        end
      end
  """

  use ExUnit.CaseTemplate

  alias Cyclium.Test.Repo

  using do
    quote do
      import Cyclium.DataCase
      import Ecto.Query
      alias Cyclium.Test.Repo
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    Application.put_env(:cyclium, :repo, Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      Application.delete_env(:cyclium, :repo)
    end)

    :ok
  end

  @doc "Insert an episode with sensible defaults, accepting field overrides."
  def insert_episode(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      trigger_type: :schedule,
      status: :running,
      attempts: 0,
      max_attempts: 3,
      started_at: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    %Cyclium.Schemas.Episode{}
    |> Cyclium.Schemas.Episode.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Insert an episode step with sensible defaults, accepting field overrides."
  def insert_step(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      step_no: 1,
      kind: :observation,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Repo.insert!(struct(Cyclium.Schemas.EpisodeStep, attrs))
  end
end

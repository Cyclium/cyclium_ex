defmodule Cyclium.EpisodeMetadataMergeDbTest do
  use ExUnit.Case, async: false

  alias Cyclium.Schemas.Episode
  alias Cyclium.Test.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:cyclium, :repo, Repo)
    on_exit(fn -> Application.delete_env(:cyclium, :repo) end)
    :ok
  end

  test "concurrent merges keep every key" do
    episode =
      %Episode{}
      |> Episode.changeset(%{
        actor_id: "metadata_merge_actor",
        expectation_id: "merge",
        trigger_type: :manual,
        status: :running,
        started_at: DateTime.utc_now(),
        metadata: %{"model" => "m-1"}
      })
      |> Repo.insert!()

    1..25
    |> Enum.map(fn i ->
      Task.async(fn -> Cyclium.Episodes.merge_metadata(episode.id, %{"k#{i}" => i}) end)
    end)
    |> Enum.each(fn task -> assert {:ok, _} = Task.await(task, 5_000) end)

    metadata = Repo.get!(Episode, episode.id).metadata
    assert metadata["model"] == "m-1"
    assert Enum.all?(1..25, &(metadata["k#{&1}"] == &1))
  end
end

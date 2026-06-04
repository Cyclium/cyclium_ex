defmodule Cyclium.Output.RouterStepNoDbTest do
  @moduledoc """
  Regression test: output steps journaled by the router must use
  `Cyclium.Episodes.next_step_no/1` (current max + 1), not the current max.

  An earlier operator-precedence bug (`repo().one() || 0 |> Kernel.+(1)`) made
  the router journal output steps at the existing max step_no, colliding with
  prior steps and with each other.
  """
  use Cyclium.DataCase

  alias Cyclium.Output.Router
  alias Cyclium.OutputProposal
  alias Cyclium.Schemas.EpisodeStep

  defmodule SuccessAdapter do
    @behaviour Cyclium.Output.Adapter
    def deliver(_type, _payload, _ctx), do: {:ok, %{message_id: "ok"}}
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.RouterStepNoPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.RouterStepNoPubSub)
    Application.put_env(:cyclium, :output_adapters, %{email: SuccessAdapter})

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :output_adapters)
    end)

    :ok
  end

  test "output steps increment past existing steps instead of colliding" do
    episode = insert_episode(%{})
    # Pre-existing journal: steps 1 and 2 (e.g. tool_call, finding_raised).
    insert_step(%{episode_id: episode.id, step_no: 1})
    insert_step(%{episode_id: episode.id, step_no: 2})

    for i <- 1..2 do
      proposal = %OutputProposal{
        type: :email,
        dedupe_key: "email:#{episode.id}:#{i}",
        payload: %{to: "a@b.co"}
      }

      assert {:ok, _} = Router.route(proposal, episode, %{})
    end

    output_step_nos =
      from(s in EpisodeStep,
        where: s.episode_id == ^episode.id and s.kind == :output_delivered,
        order_by: s.step_no,
        select: s.step_no
      )
      |> Repo.all()

    # Strictly increasing, continuing past the prior max of 2 — not [2, 2].
    assert output_step_nos == [3, 4]

    all_step_nos =
      from(s in EpisodeStep, where: s.episode_id == ^episode.id, select: s.step_no)
      |> Repo.all()

    assert Enum.sort(all_step_nos) == [1, 2, 3, 4]
  end
end

defmodule Cyclium.Output.ExactlyOnceDbTest do
  @moduledoc """
  The invariant the fencing/claim machinery exists to protect, asserted under
  real concurrency rather than a single staged interleaving: for one
  `dedupe_key`, no matter how many nodes/processes race `Router.route/3`, the
  external adapter is invoked **exactly once** and **exactly one** output row is
  written.

  Directly exercises the insert-before-deliver ordering: if a refactor ever moved
  `deliver` ahead of the unique-index insert gate (or dropped the gate), the
  delivery counter would exceed one and this test fails, where the example-based
  dedup tests would not.
  """
  use Cyclium.DataCase

  alias Cyclium.Output.Router
  alias Cyclium.OutputProposal
  alias Cyclium.Schemas.Output

  defmodule CountingAdapter do
    @behaviour Cyclium.Output.Adapter

    # Tallies real adapter invocations in a shared Agent so the test can assert
    # exactly-once delivery across concurrent racers (deliver runs in each Task).
    def deliver(_type, _payload, _ctx) do
      Agent.update(__MODULE__.Counter, &(&1 + 1))
      {:ok, %{message_id: "ok"}}
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.ExactlyOncePubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.ExactlyOncePubSub)
    Application.put_env(:cyclium, :output_adapters, %{email: CountingAdapter})

    start_supervised!(%{
      id: CountingAdapter.Counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: CountingAdapter.Counter]]}
    })

    # Let the spawned racer tasks share this test's sandboxed connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :output_adapters)
    end)

    :ok
  end

  test "N concurrent routes of one dedupe_key deliver exactly once" do
    episode = insert_episode(%{})
    dedupe_key = "email:#{episode.id}:once"

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Router.route(
            %OutputProposal{type: :email, dedupe_key: dedupe_key, payload: %{to: "a@b.co"}},
            episode,
            %{}
          )
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # Exactly one racer wins the unique-index insert; the rest see the existing row.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:duplicate, _}, &1)) == 7

    # The external side effect fired exactly once (insert gates delivery).
    assert Agent.get(CountingAdapter.Counter, & &1) == 1

    # And exactly one row persisted for the key.
    assert Repo.aggregate(from(o in Output, where: o.dedupe_key == ^dedupe_key), :count) == 1
  end
end

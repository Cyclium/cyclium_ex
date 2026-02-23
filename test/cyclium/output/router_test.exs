defmodule Cyclium.Output.RouterTest do
  use ExUnit.Case, async: false

  alias Cyclium.Output.Router
  alias Cyclium.OutputProposal

  defmodule SuccessAdapter do
    @behaviour Cyclium.Output.Adapter
    def deliver(_type, _payload, _ctx), do: {:ok, %{message_id: "msg-001"}}
  end

  defmodule FailAdapter do
    @behaviour Cyclium.Output.Adapter
    def deliver(_type, _payload, _ctx), do: {:error, :timeout}
  end

  setup do
    {:ok, _} = Cyclium.FakeRepo.start_link()
    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)

    start_supervised!({Phoenix.PubSub, name: Cyclium.TestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.TestPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :repo)
      Application.delete_env(:cyclium, :pubsub)
      Application.delete_env(:cyclium, :output_adapters)
    end)

    episode = %Cyclium.Schemas.Episode{
      id: Ecto.UUID.generate(),
      actor_id: "test_actor",
      expectation_id: "test_exp",
      status: :running
    }

    %{episode: episode}
  end

  describe "route/3 with adapter" do
    test "delivers successfully via adapter", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{email: SuccessAdapter})

      proposal = %OutputProposal{
        type: :email,
        dedupe_key: "email:test:#{Ecto.UUID.generate()}",
        payload: %{to: "test@example.com", body: "hello"}
      }

      assert {:ok, output} = Router.route(proposal, episode, %{})
      assert output.status == :delivered
      assert output.delivered_ref == %{message_id: "msg-001"}
    end

    test "returns error when adapter fails", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{slack: FailAdapter})

      proposal = %OutputProposal{
        type: :slack,
        dedupe_key: "slack:test:#{Ecto.UUID.generate()}",
        payload: %{channel: "#test"}
      }

      assert {:error, :timeout} = Router.route(proposal, episode, %{})
    end

    test "returns error when no adapter configured", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{})

      proposal = %OutputProposal{
        type: :webhook,
        dedupe_key: "webhook:test:#{Ecto.UUID.generate()}",
        payload: %{url: "https://example.com"}
      }

      assert {:error, :no_adapter} = Router.route(proposal, episode, %{})
    end
  end

  describe "deduplication" do
    test "duplicate dedupe_key returns {:duplicate, existing}", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{email: SuccessAdapter})
      dedupe_key = "email:test:dedup-#{Ecto.UUID.generate()}"

      proposal = %OutputProposal{
        type: :email,
        dedupe_key: dedupe_key,
        payload: %{to: "test@example.com"}
      }

      assert {:ok, _output} = Router.route(proposal, episode, %{})
      assert {:duplicate, existing} = Router.route(proposal, episode, %{})
      assert existing.dedupe_key == dedupe_key
    end
  end

  describe "telemetry" do
    test "emits :delivered telemetry on success", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{email: SuccessAdapter})

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-delivered-#{inspect(ref)}",
        [:cyclium, :output, :delivered],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      proposal = %OutputProposal{
        type: :email,
        dedupe_key: "email:telemetry:#{Ecto.UUID.generate()}",
        payload: %{}
      }

      Router.route(proposal, episode, %{})

      assert_receive {:telemetry, [:cyclium, :output, :delivered], %{count: 1}, meta}
      assert meta.type == "email"

      :telemetry.detach("test-delivered-#{inspect(ref)}")
    end

    test "emits :deduplicated telemetry on duplicate", %{episode: episode} do
      Application.put_env(:cyclium, :output_adapters, %{email: SuccessAdapter})

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-dedup-#{inspect(ref)}",
        [:cyclium, :output, :deduplicated],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      dedupe_key = "email:dedup-telemetry:#{Ecto.UUID.generate()}"

      proposal = %OutputProposal{
        type: :email,
        dedupe_key: dedupe_key,
        payload: %{}
      }

      Router.route(proposal, episode, %{})
      Router.route(proposal, episode, %{})

      assert_receive {:telemetry, [:cyclium, :output, :deduplicated], %{count: 1}, _meta}

      :telemetry.detach("test-dedup-#{inspect(ref)}")
    end
  end
end

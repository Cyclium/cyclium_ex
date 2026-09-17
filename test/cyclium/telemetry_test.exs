defmodule Cyclium.TelemetryTest do
  use ExUnit.Case

  test "events/0 includes all Phase 3 events" do
    events = Cyclium.Telemetry.events()

    assert [:cyclium, :output, :delivered] in events
    assert [:cyclium, :output, :failed] in events
    assert [:cyclium, :output, :deduplicated] in events
    assert [:cyclium, :finding, :raised] in events
    assert [:cyclium, :finding, :cleared] in events
    assert [:cyclium, :episode, :completed] in events
    assert [:cyclium, :episode, :failed] in events
    assert [:cyclium, :episode, :dropped] in events
  end

  test "attach_default_logger/0 attaches without error" do
    :telemetry.detach("cyclium-default-logger")
    assert :ok = Cyclium.Telemetry.attach_default_logger()
    :telemetry.detach("cyclium-default-logger")
  end

  test "attach_default_logger returns error when already attached" do
    :telemetry.detach("cyclium-default-logger")
    :ok = Cyclium.Telemetry.attach_default_logger()
    assert {:error, :already_exists} = Cyclium.Telemetry.attach_default_logger()
    :telemetry.detach("cyclium-default-logger")
  end

  describe "background-work spans" do
    @span_events [
      [:cyclium, :background_work, :start],
      [:cyclium, :background_work, :stop],
      [:cyclium, :background_work, :exception]
    ]

    setup do
      test_pid = self()
      handler_id = {__MODULE__, System.unique_integer([:positive])}

      :telemetry.attach_many(
        handler_id,
        @span_events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "span_events/0 are listed separately and kept out of events/0" do
      assert Cyclium.Telemetry.span_events() == @span_events

      Enum.each(@span_events, fn event ->
        refute event in Cyclium.Telemetry.events()
      end)
    end

    test "span/3 brackets the work with a start/stop pair, tagged by work" do
      assert :ok =
               Cyclium.Telemetry.span(:some_worker, %{node: "n1", source_env: "uat"}, fn ->
                 {:ok, %{result: %{processed: 3}}}
               end)

      assert_receive {:telemetry, [:cyclium, :background_work, :start], start_meas, start_meta}
      assert is_integer(start_meas.system_time)
      assert start_meta.work == :some_worker
      assert start_meta.node == "n1"
      assert start_meta.source_env == "uat"

      assert_receive {:telemetry, [:cyclium, :background_work, :stop], stop_meas, stop_meta}
      assert stop_meas.duration > 0
      # Scope from :start rides through to :stop, and the tick's result rides with it.
      assert stop_meta.work == :some_worker
      assert stop_meta.result == %{processed: 3}
    end

    test "span/3 returns the work's result to the caller" do
      assert {:ok, %{count: 7}} =
               Cyclium.Telemetry.span(:some_worker, %{node: "n1"}, fn ->
                 {{:ok, %{count: 7}}, %{result: %{count: 7}}}
               end)
    end

    test "span/3 emits :exception and re-raises when the work raises" do
      assert_raise RuntimeError, "boom", fn ->
        Cyclium.Telemetry.span(:some_worker, %{node: "n1"}, fn ->
          raise "boom"
        end)
      end

      assert_receive {:telemetry, [:cyclium, :background_work, :exception], meas, meta}
      assert meas.duration > 0
      assert meta.work == :some_worker
      assert meta.kind == :error
    end
  end
end

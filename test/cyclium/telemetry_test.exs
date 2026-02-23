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
end

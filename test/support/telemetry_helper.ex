defmodule Cyclium.TelemetryHelper do
  @moduledoc """
  Module-level telemetry handler for tests. Avoids the anonymous function
  warning from :telemetry.attach/4.
  """

  def handle_event(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end

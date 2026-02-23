defmodule Cyclium do
  @moduledoc """
  Cyclium — an Elixir library for event-driven, expectation-based agent orchestration.

  Provides primitives to define actors that watch the world, evaluate expectations,
  investigate when things drift, and produce typed outputs — all with auditable
  provenance, bounded execution, and OTP-native supervision.
  """

  def repo do
    Application.fetch_env!(:cyclium, :repo)
  end
end

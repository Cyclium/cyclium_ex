defmodule Cyclium.Runner do
  @moduledoc """
  Behaviour for episode execution backends.
  Default is `Cyclium.Runner.OTP`. Can be swapped for Oban-backed runner.
  """

  @callback enqueue(episode_id :: binary(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback recover_incomplete() :: :ok

  @callback cancel(episode_id :: binary()) :: :ok | {:error, term()}
end

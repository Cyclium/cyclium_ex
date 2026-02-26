defmodule Cyclium.WorkClaims do
  @moduledoc """
  Behaviour for lease-based distributed work claiming.

  When configured, ensures at-most-once execution of episodes across
  clustered nodes. Each episode's `dedupe_key` is claimed before execution —
  only the node holding an active lease runs the work.

  ## Configuration

      # Use the built-in Ecto-based implementation:
      config :cyclium, work_claims: Cyclium.WorkClaims.EctoClaims

      # Or a SQL Server-optimized adapter in consuming apps:
      config :cyclium, work_claims: MyApp.WorkClaims.SqlServer

      # Or omit entirely — no claiming, fully backwards compatible

  ## Gate functions

  All integration points use `gate_*` functions which return
  `{:ok, :passthrough}` when no implementation is configured. This
  makes work claims opt-in with zero impact on existing deployments.
  """

  alias Cyclium.Schemas.WorkClaim

  @type acquire_result :: {:ok, WorkClaim.t()} | {:error, :busy}
  @type owner_result :: :ok | {:error, :not_owner}

  @callback acquire(dedupe_key :: String.t(), owner_node :: String.t(), opts :: keyword()) ::
              acquire_result()

  @callback renew(
              dedupe_key :: String.t(),
              owner_node :: String.t(),
              lease_seconds :: pos_integer()
            ) ::
              owner_result()

  @callback complete(dedupe_key :: String.t(), owner_node :: String.t()) ::
              owner_result()

  @callback fail(dedupe_key :: String.t(), owner_node :: String.t(), error_detail :: map()) ::
              owner_result()

  @callback reclaim_expired(limit :: pos_integer()) ::
              {:ok, [WorkClaim.t()]}

  # --- Gate dispatch functions ---

  @doc """
  Attempt to acquire a lease on `dedupe_key`. Returns `{:ok, :passthrough}`
  if work claims are not configured.
  """
  def gate_acquire(dedupe_key, owner_node, opts \\ []) do
    case impl() do
      nil -> {:ok, :passthrough}
      mod -> mod.acquire(dedupe_key, owner_node, opts)
    end
  end

  @doc """
  Renew the lease for `dedupe_key`. No-op if unconfigured.
  """
  def gate_renew(dedupe_key, owner_node, lease_seconds) do
    case impl() do
      nil -> :ok
      mod -> mod.renew(dedupe_key, owner_node, lease_seconds)
    end
  end

  @doc """
  Mark work as completed. No-op if unconfigured.
  """
  def gate_complete(dedupe_key, owner_node) do
    case impl() do
      nil -> :ok
      mod -> mod.complete(dedupe_key, owner_node)
    end
  end

  @doc """
  Mark work as failed. No-op if unconfigured.
  """
  def gate_fail(dedupe_key, owner_node, error_detail \\ %{}) do
    case impl() do
      nil -> :ok
      mod -> mod.fail(dedupe_key, owner_node, error_detail)
    end
  end

  @doc """
  Reclaim up to `limit` expired claims. Returns empty list if unconfigured.
  """
  def gate_reclaim_expired(limit \\ 100) do
    case impl() do
      nil -> {:ok, []}
      mod -> mod.reclaim_expired(limit)
    end
  end

  @doc false
  def configured?, do: impl() != nil

  defp impl do
    Application.get_env(:cyclium, :work_claims, nil)
  end
end

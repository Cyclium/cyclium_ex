defmodule Cyclium.WorkClaims.FakeClaims do
  @moduledoc """
  In-memory work claims implementation for tests.

  Uses an Agent to track claims. All acquires succeed by default.
  Use `set_busy/2` to simulate contention.

  ## Usage

      # In test setup:
      {:ok, _} = Cyclium.WorkClaims.FakeClaims.start_link()
      Application.put_env(:cyclium, :work_claims, Cyclium.WorkClaims.FakeClaims)

      # Simulate contention:
      Cyclium.WorkClaims.FakeClaims.set_busy("some:dedupe:key")
  """

  @behaviour Cyclium.WorkClaims

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{claims: %{}, busy_keys: MapSet.new()} end, name: name)
  end

  @doc "Mark a dedupe_key as busy — acquire will return `{:error, :busy}`."
  def set_busy(dedupe_key, name \\ __MODULE__) do
    Agent.update(name, fn state ->
      %{state | busy_keys: MapSet.put(state.busy_keys, dedupe_key)}
    end)
  end

  @doc "Clear busy status for a dedupe_key."
  def clear_busy(dedupe_key, name \\ __MODULE__) do
    Agent.update(name, fn state ->
      %{state | busy_keys: MapSet.delete(state.busy_keys, dedupe_key)}
    end)
  end

  @doc "Get all current claims."
  def get_claims(name \\ __MODULE__) do
    Agent.get(name, & &1.claims)
  end

  @impl true
  def acquire(dedupe_key, owner_node, opts \\ []) do
    Agent.get_and_update(__MODULE__, fn state ->
      if MapSet.member?(state.busy_keys, dedupe_key) do
        {{:error, :busy}, state}
      else
        claim = %Cyclium.Schemas.WorkClaim{
          id: Ecto.UUID.generate(),
          dedupe_key: dedupe_key,
          state: :claimed,
          owner_node: owner_node,
          lease_until: DateTime.add(DateTime.utc_now(), Keyword.get(opts, :lease_seconds, 120)),
          claimed_at: DateTime.utc_now(),
          attempt: 1,
          work_type: Keyword.get(opts, :work_type)
        }

        new_claims = Map.put(state.claims, dedupe_key, claim)
        {{:ok, claim}, %{state | claims: new_claims}}
      end
    end)
  end

  @impl true
  def renew(dedupe_key, _owner_node, lease_seconds) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.claims, dedupe_key) do
        nil ->
          {{:error, :not_owner}, state}

        claim ->
          updated = %{claim | lease_until: DateTime.add(DateTime.utc_now(), lease_seconds)}
          {:ok, %{state | claims: Map.put(state.claims, dedupe_key, updated)}}
      end
    end)
  end

  @impl true
  def complete(dedupe_key, _owner_node) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.claims, dedupe_key) do
        nil ->
          {{:error, :not_owner}, state}

        claim ->
          updated = %{claim | state: :done, finished_at: DateTime.utc_now()}
          {:ok, %{state | claims: Map.put(state.claims, dedupe_key, updated)}}
      end
    end)
  end

  @impl true
  def fail(dedupe_key, _owner_node, error_detail \\ %{}) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.claims, dedupe_key) do
        nil ->
          {{:error, :not_owner}, state}

        claim ->
          updated = %{
            claim
            | state: :failed,
              finished_at: DateTime.utc_now(),
              error_detail: error_detail
          }

          {:ok, %{state | claims: Map.put(state.claims, dedupe_key, updated)}}
      end
    end)
  end

  @impl true
  def reclaim_expired(_limit \\ 100) do
    {:ok, []}
  end
end

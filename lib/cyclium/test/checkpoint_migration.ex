defmodule Cyclium.Test.CheckpointMigration do
  @moduledoc """
  Test helpers for property-based testing of checkpoint schema migrations.

  Provides generators and assertion helpers so host apps can verify that
  `migrate/2` callbacks safely transform any V1 state to the current version.

  Requires `{:stream_data, "~> 1.0", only: :test}` in your deps.

  ## Usage

      defmodule MyApp.Checkpoints.POInvestigationTest do
        use ExUnit.Case, async: true
        use Cyclium.Test.CheckpointMigration

        describe "migration safety" do
          test "v1 -> current succeeds for any state" do
            assert_migration_safe(MyApp.Checkpoints.POInvestigation,
              from: 1,
              generator: fn ->
                StreamData.fixed_map(%{
                  "vendor_id" => StreamData.string(:alphanumeric, min_length: 1),
                  "vendor_contacts" => StreamData.list_of(
                    StreamData.map_of(
                      StreamData.string(:alphanumeric),
                      StreamData.string(:alphanumeric)
                    )
                  )
                })
              end
            )
          end
        end
      end

  If no generator is provided, a default fuzz generator produces random
  nested maps with string keys and mixed-type values.
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Test.CheckpointMigration
    end
  end

  @doc """
  Assert that migrating from `from` to current version succeeds for all
  generated states. Runs 100 iterations by default.

  ## Options

    * `:from` — starting version (required)
    * `:generator` — 0-arity function returning a StreamData generator (optional)
    * `:iterations` — number of property test iterations (default: 100)
  """
  defmacro assert_migration_safe(schema_module, opts) do
    quote bind_quoted: [schema_module: schema_module, opts: opts] do
      from = Keyword.fetch!(opts, :from)
      iterations = Keyword.get(opts, :iterations, 100)

      generator =
        case Keyword.get(opts, :generator) do
          nil -> Cyclium.Test.CheckpointMigration.default_state_generator()
          gen_fn -> gen_fn.()
        end

      generator
      |> Enum.take(iterations)
      |> Enum.each(fn state ->
        case schema_module.migrate_to_current(from, state) do
          {:ok, migrated} ->
            assert is_map(migrated),
                   "migrate_to_current(#{from}, #{inspect(state)}) returned non-map: #{inspect(migrated)}"

          {:error, reason} ->
            flunk("migrate_to_current(#{from}, #{inspect(state)}) failed: #{inspect(reason)}")
        end
      end)
    end
  end

  @doc """
  Assert that migrating a specific state from one version to current produces
  the expected result.
  """
  defmacro assert_migration(schema_module, from, state, expected) do
    quote bind_quoted: [
            schema_module: schema_module,
            from: from,
            state: state,
            expected: expected
          ] do
      assert {:ok, ^expected} = schema_module.migrate_to_current(from, state)
    end
  end

  @doc """
  Assert that migration is idempotent — migrating an already-current state
  returns it unchanged.
  """
  defmacro assert_migration_idempotent(schema_module, state) do
    quote bind_quoted: [schema_module: schema_module, state: state] do
      version = schema_module.__checkpoint_version__()
      assert {:ok, ^state} = schema_module.migrate_to_current(version, state)
    end
  end

  @doc """
  Returns a default StreamData generator for random map states with
  string keys and mixed values. Useful for fuzz testing migrations
  that should be resilient to unexpected keys.

  Only callable at test time (requires StreamData).
  """
  def default_state_generator do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      leaf_generator(),
      max_length: 10
    )
  end

  defp leaf_generator do
    StreamData.one_of([
      StreamData.string(:alphanumeric, max_length: 50),
      StreamData.integer(),
      StreamData.float(min: -1000.0, max: 1000.0),
      StreamData.boolean(),
      StreamData.constant(nil),
      StreamData.list_of(StreamData.string(:alphanumeric, max_length: 20), max_length: 5)
    ])
  end
end

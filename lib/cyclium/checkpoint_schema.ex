defmodule Cyclium.CheckpointSchema do
  @moduledoc """
  Macro for defining versioned checkpoint schemas with migration support.

  Checkpoint schemas declare the current version and provide `migrate/2`
  callbacks that transform state from older versions to the current one.

  ## Usage

      defmodule MyApp.Checkpoints.POInvestigation do
        use Cyclium.CheckpointSchema, version: 2

        def migrate(1, state) do
          contacts = (state["vendor_contacts"] || [])
                     |> Enum.group_by(& &1["vendor_id"])
          {:ok, Map.put(state, "vendor_contacts", contacts)}
        end

        def migrate(2, state), do: {:ok, state}
        def migrate(_v, _state), do: {:error, :unsupported_version}
      end

  ## Registration

  Declare the schema on the expectation (preferred — keeps it next to the
  strategy whose state it versions):

      expectation(:investigate_po,
        strategy: MyApp.Strategies.POInvestigation,
        checkpoint_schema: MyApp.Checkpoints.POInvestigation,
        ...
      )

  Or register in app config, which takes precedence over the expectation
  declaration (useful as a deploy-time override):

      config :cyclium, :checkpoint_schemas, %{
        {"my_actor", "investigate_po"} => MyApp.Checkpoints.POInvestigation
      }

  ## Guidelines

  - Store IDs and refs, not full payloads
  - Keep state flat — avoid deeply nested structures
  - No raw tool responses in checkpoints
  - Normalize early before checkpointing
  """

  defmacro __using__(opts) do
    version = Keyword.fetch!(opts, :version)

    quote do
      @checkpoint_version unquote(version)

      @before_compile Cyclium.CheckpointSchema

      @doc "Returns the current checkpoint schema version."
      def __checkpoint_version__, do: @checkpoint_version

      @doc """
      Migrate state from `from_version` to the current version by chaining
      `migrate/2` calls through each intermediate version.

      Returns `{:ok, migrated_state}` or `{:error, reason}`.
      """
      def migrate_to_current(from_version, state) do
        Cyclium.CheckpointSchema.chain_migrate(
          __MODULE__,
          from_version,
          @checkpoint_version,
          state
        )
      end
    end
  end

  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:migrate, 2}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(env.module)} must define migrate/2 callbacks"
    end

    :ok
  end

  @doc """
  Resolve the checkpoint schema module for an actor/expectation pair.

  Precedence:

    1. App-config override — `config :cyclium, :checkpoint_schemas`, keyed by
       `{actor_id, expectation_id}` or `actor_id` (matched against the raw
       episode values, which are strings for DB-loaded episodes)
    2. Expectation-declared schema (`checkpoint_schema: MyModule`), registered
       in persistent_term when the actor boots

  Returns `nil` when no schema is registered. Used by both the checkpoint
  write path (version stamping) and the restore path (migration) — they must
  agree on the schema or migration chains break.
  """
  @spec resolve(atom() | binary(), atom() | binary()) :: module() | nil
  def resolve(actor_id, expectation_id) do
    schemas = Application.get_env(:cyclium, :checkpoint_schemas, %{})

    Map.get(schemas, {actor_id, expectation_id}) ||
      Map.get(schemas, actor_id) ||
      registered(actor_id, expectation_id)
  end

  defp registered(actor_id, expectation_id) do
    with {:ok, actor} <- to_existing_atom(actor_id),
         {:ok, exp} <- to_existing_atom(expectation_id) do
      :persistent_term.get({:cyclium_expectation_checkpoint_schema, actor, exp}, nil)
    else
      # No existing atom means no actor booted under this id on this node,
      # so there is no registration to find.
      :error -> nil
    end
  end

  defp to_existing_atom(value) when is_atom(value), do: {:ok, value}
  defp to_existing_atom(value) when is_binary(value), do: Cyclium.AtomGuard.existing_atom(value)

  @doc """
  True when `state` survives a JSON round-trip unchanged — the constraint every
  checkpoint state must satisfy.

  `save_checkpoint` persists state into a `:map` (nvarchar(max)) column, so the
  Ecto/TDS adapter `Jason.encode!`s it on write and the restore path
  `Jason.decode!`s it on read. Values that encode but don't *round-trip* are the
  quiet trap: atom keys and atom values become strings, tuples fail to encode at
  all, and structs either crash or lose their identity. Because `init/2` is not
  re-run on resume, a state that silently changed shape comes back subtly wrong.

  Use this (or `assert_json_plain!/1`) in a strategy's checkpoint test to guard
  the constraint at the source rather than discovering it after a resume.

      test "checkpoint state stays JSON-plain" do
        assert Cyclium.CheckpointSchema.json_plain?(MyStrategy.initial_state())
      end
  """
  @spec json_plain?(term()) :: boolean()
  def json_plain?(state) do
    case Jason.encode(state) do
      {:ok, json} -> Jason.decode(json) == {:ok, state}
      {:error, _} -> false
    end
  end

  @doc """
  Raises `ArgumentError` unless `state` survives a JSON round-trip unchanged.
  The bang companion to `json_plain?/1`, for use as a test assertion.
  """
  @spec assert_json_plain!(term()) :: :ok
  def assert_json_plain!(state) do
    case Jason.encode(state) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, ^state} ->
            :ok

          {:ok, decoded} ->
            raise ArgumentError,
                  "checkpoint state encodes but does not round-trip — it changed shape " <>
                    "through JSON (atom keys/values become strings, etc.).\n" <>
                    "  before: #{inspect(state)}\n  after:  #{inspect(decoded)}"
        end

      {:error, e} ->
        raise ArgumentError,
              "checkpoint state is not JSON-encodable (tuples/structs are common culprits): " <>
                Exception.message(e)
    end
  end

  @doc false
  def chain_migrate(_module, version, version, state), do: {:ok, state}

  def chain_migrate(module, from, to, state) when from < to do
    case module.migrate(from, state) do
      {:ok, new_state} -> chain_migrate(module, from + 1, to, new_state)
      {:error, _} = err -> err
    end
  end

  def chain_migrate(_module, from, to, _state) when from > to do
    {:error, {:version_ahead, from, to}}
  end
end

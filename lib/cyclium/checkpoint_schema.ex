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

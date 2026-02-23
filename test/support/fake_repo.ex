defmodule Cyclium.FakeRepo do
  @moduledoc """
  In-memory fake repo for unit tests that need repo operations
  without a real database. Uses an Agent to store records.

  ## Usage

      setup do
        {:ok, _} = Cyclium.FakeRepo.start_link()
        Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
        on_exit(fn -> Application.delete_env(:cyclium, :repo) end)
        :ok
      end
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{records: [], next_id: 1} end, name: __MODULE__)
  end

  def insert(changeset, _opts \\ []) do
    if changeset.valid? do
      record = Ecto.Changeset.apply_changes(changeset)
      record = ensure_id(record)

      # Check unique constraints
      case check_unique_constraints(changeset, record) do
        :ok ->
          Agent.update(__MODULE__, fn state ->
            %{state | records: [record | state.records]}
          end)
          {:ok, record}

        {:error, field} ->
          {:error, Ecto.Changeset.add_error(changeset, field, "has already been taken", constraint: :unique)}
      end
    else
      {:error, changeset}
    end
  end

  def insert!(struct_or_changeset, _opts \\ []) do
    case struct_or_changeset do
      %Ecto.Changeset{} = cs ->
        case insert(cs) do
          {:ok, record} -> record
          {:error, cs} -> raise Ecto.InvalidChangesetError, changeset: cs, action: :insert
        end

      %{__struct__: _} = struct ->
        record = ensure_id(struct)
        Agent.update(__MODULE__, fn state ->
          %{state | records: [record | state.records]}
        end)
        record
    end
  end

  def update(changeset) do
    if changeset.valid? do
      record = Ecto.Changeset.apply_changes(changeset)
      Agent.update(__MODULE__, fn state ->
        updated = Enum.map(state.records, fn r ->
          if r.__struct__ == record.__struct__ && Map.get(r, :id) == Map.get(record, :id) do
            record
          else
            r
          end
        end)
        %{state | records: updated}
      end)
      {:ok, record}
    else
      {:error, changeset}
    end
  end

  def get_by(schema, clauses) do
    Agent.get(__MODULE__, fn state ->
      Enum.find(state.records, fn r ->
        r.__struct__ == schema &&
          Enum.all?(clauses, fn {k, v} -> Map.get(r, k) == v end)
      end)
    end)
  end

  def get_by!(schema, clauses) do
    case get_by(schema, clauses) do
      nil -> raise Ecto.NoResultsError, queryable: schema
      record -> record
    end
  end

  def one(_query) do
    # Default: return nil (used by next_step_no queries)
    nil
  end

  def update_all(_query, _updates) do
    {0, nil}
  end

  def transaction(fun) when is_function(fun, 1) do
    try do
      result = fun.(__MODULE__)
      {:ok, result}
    rescue
      e -> {:error, e}
    end
  end

  def all(_query) do
    []
  end

  # --- Helpers ---

  defp ensure_id(%{id: nil} = record) do
    %{record | id: Ecto.UUID.generate()}
  end

  defp ensure_id(%{id: _} = record), do: record
  defp ensure_id(record), do: record

  defp check_unique_constraints(changeset, record) do
    constraints = changeset.constraints
    |> Enum.filter(fn c -> c.type == :unique end)

    conflict = Enum.find(constraints, fn c ->
      Agent.get(__MODULE__, fn state ->
        Enum.any?(state.records, fn existing ->
          existing.__struct__ == record.__struct__ &&
            fields_match?(existing, record, c.field)
        end)
      end)
    end)

    case conflict do
      nil -> :ok
      c -> {:error, c.field}
    end
  end

  defp fields_match?(existing, record, fields) when is_list(fields) do
    Enum.all?(fields, fn f -> Map.get(existing, f) == Map.get(record, f) end)
  end

  defp fields_match?(existing, record, field) when is_atom(field) do
    Map.get(existing, field) == Map.get(record, field)
  end
end

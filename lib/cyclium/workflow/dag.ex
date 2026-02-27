defmodule Cyclium.Workflow.DAG do
  @moduledoc """
  Shared DAG validation for workflow step dependencies.

  Used by both the compile-time Workflow DSL and the runtime
  DynamicWorkflow.Loader to detect circular dependencies.
  """

  @doc """
  Validates that a set of steps forms a valid DAG (no circular dependencies).

  Accepts a map of `%{step_id => [dependency_ids]}`.
  Returns `:ok` or raises with the cycle node.
  """
  def validate!(adjacency) do
    case topo_sort(adjacency, Map.keys(adjacency)) do
      {:ok, _order} -> :ok
      {:error, cycle_node} -> {:error, {:cycle, cycle_node}}
    end
  end

  @doc """
  Validates step references: all depends_on entries must reference existing step IDs.
  """
  def validate_references!(adjacency) do
    all_ids = MapSet.new(Map.keys(adjacency))

    Enum.each(adjacency, fn {step_id, deps} ->
      Enum.each(deps, fn dep ->
        unless MapSet.member?(all_ids, dep) do
          {:error, {:unknown_dependency, step_id, dep}}
        end
      end)
    end)

    :ok
  end

  @doc """
  Topological sort of a DAG. Returns `{:ok, ordered_list}` or `{:error, cycle_node}`.
  """
  def topo_sort(adj, nodes) do
    state = %{visited: MapSet.new(), in_stack: MapSet.new(), order: []}

    Enum.reduce_while(nodes, {:ok, state}, fn node, {:ok, acc} ->
      if MapSet.member?(acc.visited, node) do
        {:cont, {:ok, acc}}
      else
        case visit(node, adj, acc) do
          {:ok, new_acc} -> {:cont, {:ok, new_acc}}
          {:error, _} = err -> {:halt, err}
        end
      end
    end)
    |> case do
      {:ok, state} -> {:ok, Enum.reverse(state.order)}
      {:error, _} = err -> err
    end
  end

  defp visit(node, adj, state) do
    if MapSet.member?(state.in_stack, node) do
      {:error, node}
    else
      state = %{state | in_stack: MapSet.put(state.in_stack, node)}
      deps = Map.get(adj, node, [])

      result =
        Enum.reduce_while(deps, {:ok, state}, fn dep, {:ok, acc} ->
          if MapSet.member?(acc.visited, dep) do
            {:cont, {:ok, acc}}
          else
            case visit(dep, adj, acc) do
              {:ok, new_acc} -> {:cont, {:ok, new_acc}}
              {:error, _} = err -> {:halt, err}
            end
          end
        end)

      case result do
        {:ok, state} ->
          {:ok,
           %{
             state
             | visited: MapSet.put(state.visited, node),
               in_stack: MapSet.delete(state.in_stack, node),
               order: [node | state.order]
           }}

        {:error, _} = err ->
          err
      end
    end
  end
end

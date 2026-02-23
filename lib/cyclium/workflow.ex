defmodule Cyclium.Workflow do
  @moduledoc """
  Macro for defining multi-actor workflows.

  ## Usage

      defmodule MyApp.Workflows.VendorOnboarding do
        use Cyclium.Workflow

        workflow do
          trigger {:event, "vendor.registration_submitted"}

          step :compliance_check,
            actor: MyApp.Actors.Compliance,
            expectation: :vendor_risk,
            input: fn trigger, _prior -> %{vendor_id: trigger["vendor_id"]} end

          step :connector_setup,
            actor: MyApp.Actors.Integration,
            expectation: :setup_connector,
            depends_on: [:compliance_check],
            input: fn trigger, prior ->
              %{vendor_id: trigger["vendor_id"], risk: prior.compliance_check.vendor_risk}
            end

          on_failure :compliance_check, :abort
          on_failure :connector_setup, :retry, max_step_attempts: 2, backoff_ms: 30_000
        end
      end

  The generated module provides:
  - `__workflow_config__/0` — returns `%Cyclium.Workflow.Config{}` with all step metadata
  - `__workflow_step_input__/3` — dispatches `(step_id, trigger, prior)` to the input function
  """

  defmacro __using__(_opts) do
    quote do
      import Cyclium.Workflow.DSL

      Module.register_attribute(__MODULE__, :cyclium_wf_trigger, accumulate: false)
      Module.register_attribute(__MODULE__, :cyclium_wf_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :cyclium_wf_failure_policies, accumulate: true)

      @before_compile Cyclium.Workflow
    end
  end

  defmacro __before_compile__(env) do
    trigger = Module.get_attribute(env.module, :cyclium_wf_trigger)
    steps = Module.get_attribute(env.module, :cyclium_wf_steps) || []
    policies = Module.get_attribute(env.module, :cyclium_wf_failure_policies) || []

    unless trigger do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(env.module)}: workflow must declare a trigger"
    end

    step_ids = Enum.map(steps, & &1.id)

    dupes = step_ids -- Enum.uniq(step_ids)

    if dupes != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(env.module)}: duplicate step IDs: #{inspect(Enum.uniq(dupes))}"
    end

    step_id_set = MapSet.new(step_ids)

    Enum.each(steps, fn step ->
      Enum.each(step.depends_on, fn dep ->
        unless MapSet.member?(step_id_set, dep) do
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "#{inspect(env.module)}: step #{inspect(step.id)} depends_on unknown step #{inspect(dep)}"
        end
      end)
    end)

    validate_dag!(env, steps)

    # Build step data without input_fn (all escapable)
    step_data =
      steps
      |> Enum.map(fn step ->
        {step.id,
         %Cyclium.Workflow.StepConfig{
           id: step.id,
           actor: step.actor,
           expectation: step.expectation,
           input_fn: nil,
           depends_on: step.depends_on,
           requires_approval: step.requires_approval
         }}
      end)
      |> Enum.into(%{})

    policy_map =
      policies
      |> Enum.map(fn {step_id, policy_spec} -> {step_id, policy_spec} end)
      |> Enum.into(%{})

    workflow_id = to_string(env.module)

    quote do
      def __workflow_config__ do
        %Cyclium.Workflow.Config{
          workflow_id: unquote(workflow_id),
          trigger: unquote(Macro.escape(trigger)),
          steps: unquote(Macro.escape(step_data)),
          failure_policies: unquote(Macro.escape(policy_map))
        }
      end
    end
  end

  defp validate_dag!(env, steps) do
    adj = Map.new(steps, fn s -> {s.id, s.depends_on} end)

    case topo_sort(adj, Map.keys(adj)) do
      {:error, cycle_node} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)}: circular dependency detected involving step #{inspect(cycle_node)}"

      {:ok, _order} ->
        :ok
    end
  end

  defp topo_sort(adj, nodes) do
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

defmodule Cyclium.Workflow.DSL do
  @moduledoc false

  defmacro workflow(do: block) do
    block
  end

  defmacro trigger(spec) do
    quote do
      @cyclium_wf_trigger unquote(Macro.escape(spec))
    end
  end

  defmacro step(id, opts) do
    # Extract the input function AST before evaluating opts
    input_ast = Keyword.get(opts, :input)
    # Remove :input from opts for the rest
    rest_opts = Keyword.delete(opts, :input)

    # Generate a __workflow_step_input__/3 clause for this step
    input_def =
      if input_ast do
        quote do
          def __workflow_step_input__(unquote(id), var!(trigger), var!(prior)) do
            input_fn = unquote(input_ast)
            input_fn.(var!(trigger), var!(prior))
          end
        end
      else
        quote do
          def __workflow_step_input__(unquote(id), _trigger, _prior), do: %{}
        end
      end

    quote do
      unquote(input_def)

      opts = unquote(rest_opts)
      actor = Keyword.fetch!(opts, :actor)
      expectation = Keyword.fetch!(opts, :expectation)
      depends_on = Keyword.get(opts, :depends_on, [])
      requires_approval = Keyword.get(opts, :requires_approval, false)

      @cyclium_wf_steps %Cyclium.Workflow.StepConfig{
        id: unquote(id),
        actor: actor,
        expectation: expectation,
        input_fn: nil,
        depends_on: depends_on,
        requires_approval: requires_approval
      }
    end
  end

  defmacro on_failure(step_id, policy) do
    quote do
      @cyclium_wf_failure_policies {unquote(step_id), %{policy: unquote(policy)}}
    end
  end

  defmacro on_failure(step_id, policy, opts) do
    quote do
      @cyclium_wf_failure_policies {
        unquote(step_id),
        %{
          policy: unquote(policy),
          max_step_attempts: Keyword.get(unquote(opts), :max_step_attempts, 3),
          backoff_ms: Keyword.get(unquote(opts), :backoff_ms, 5_000)
        }
      }
    end
  end
end

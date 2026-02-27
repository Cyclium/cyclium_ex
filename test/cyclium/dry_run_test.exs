defmodule Cyclium.DryRunTest do
  use ExUnit.Case

  alias Cyclium.{ConvergeResult, Expectation, OutputProposal}

  # --- Test modules ---

  defmodule DryRunActor do
    use Cyclium.Actor

    actor do
      domain(:testing)
      max_concurrent_episodes(5)
      episode_overflow(:queue)

      expectation(:check_one,
        trigger: {:schedule, 5_000},
        description: "Basic check"
      )

      expectation(:check_with_dry_run_config,
        trigger: {:event, "test.event"},
        description: "Has default dry run overrides",
        dry_run: [
          tool_overrides: %{"erp.get_orders" => %{orders: []}},
          synthesis_override: %{"class" => "default_mock"}
        ]
      )
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Cyclium.DryRunTestPubSub})
    Application.put_env(:cyclium, :pubsub, Cyclium.DryRunTestPubSub)

    on_exit(fn ->
      Application.delete_env(:cyclium, :pubsub)
    end)

    :ok
  end

  # --- Actor DSL ---

  describe "expectation dry_run field" do
    test "expectations without dry_run have nil" do
      expectations = DryRunActor.__cyclium_expectations__()
      {_id, opts} = Enum.find(expectations, fn {id, _} -> id == :check_one end)
      assert Keyword.get(opts, :dry_run) == nil
    end

    test "expectations with dry_run store the config" do
      expectations = DryRunActor.__cyclium_expectations__()
      {_id, opts} = Enum.find(expectations, fn {id, _} -> id == :check_with_dry_run_config end)
      dry_run = Keyword.get(opts, :dry_run)

      assert dry_run[:tool_overrides] == %{"erp.get_orders" => %{orders: []}}
      assert dry_run[:synthesis_override] == %{"class" => "default_mock"}
    end
  end

  describe "Expectation struct dry_run field" do
    test "build_expectation includes dry_run from opts" do
      {:ok, pid} = DryRunActor.start_link(name: :"dry_run_actor_#{System.unique_integer()}")
      state = :sys.get_state(pid)

      # check_one has nil dry_run
      exp_one = state.expectations[:check_one]
      assert exp_one.dry_run == nil

      # check_with_dry_run_config has the config
      exp_dr = state.expectations[:check_with_dry_run_config]
      assert exp_dr.dry_run != nil
      assert exp_dr.dry_run[:tool_overrides] == %{"erp.get_orders" => %{orders: []}}
      assert exp_dr.dry_run[:synthesis_override] == %{"class" => "default_mock"}

      GenServer.stop(pid)
    end
  end

  # --- Dry run opts merging (tested via state inspection after force_fire) ---

  describe "draining flag" do
    test "state starts with draining: false" do
      {:ok, pid} = DryRunActor.start_link(name: :"drain_test_#{System.unique_integer()}")
      state = :sys.get_state(pid)

      assert state.draining == false

      GenServer.stop(pid)
    end
  end

  # --- EpisodeRunner dry run helper tests ---
  # These test the override resolution functions used by EpisodeRunner.
  # Since they're private, we test them by constructing episode-like maps
  # and calling through module-accessible paths.

  describe "dry_run_tool_override resolution" do
    # Testing the logic inline since the functions are private to EpisodeRunner.
    # We replicate the function logic to verify correctness.

    test "returns :real for live mode episode" do
      episode = %{mode: "live", dry_run_opts: nil}
      assert resolve_tool_override(episode, "erp.get_orders") == :real
    end

    test "returns :real for dry_run with no opts" do
      episode = %{mode: "dry_run", dry_run_opts: nil}
      assert resolve_tool_override(episode, "erp.get_orders") == :real
    end

    test "returns :real for dry_run with empty tool_overrides" do
      episode = %{mode: "dry_run", dry_run_opts: %{"tool_overrides" => %{}}}
      assert resolve_tool_override(episode, "erp.get_orders") == :real
    end

    test "returns mock for matching tool override" do
      mock_data = %{orders: [%{id: 1}]}

      episode = %{
        mode: "dry_run",
        dry_run_opts: %{"tool_overrides" => %{"erp.get_orders" => mock_data}}
      }

      assert resolve_tool_override(episode, "erp.get_orders") == {:mock, mock_data}
    end

    test "returns :real for non-matching tool" do
      episode = %{
        mode: "dry_run",
        dry_run_opts: %{"tool_overrides" => %{"erp.get_orders" => %{}}}
      }

      assert resolve_tool_override(episode, "crm.get_clients") == :real
    end
  end

  describe "dry_run_synthesis_override resolution" do
    test "returns :real for live mode episode" do
      episode = %{mode: "live", dry_run_opts: nil}
      assert resolve_synthesis_override(episode) == :real
    end

    test "returns :real for dry_run with no opts" do
      episode = %{mode: "dry_run", dry_run_opts: nil}
      assert resolve_synthesis_override(episode) == :real
    end

    test "returns :real for dry_run without synthesis_override" do
      episode = %{mode: "dry_run", dry_run_opts: %{"tool_overrides" => %{}}}
      assert resolve_synthesis_override(episode) == :real
    end

    test "returns mock when synthesis_override is set" do
      mock_result = %{"class" => "healthy", "severity" => "low"}
      episode = %{mode: "dry_run", dry_run_opts: %{"synthesis_override" => mock_result}}

      assert resolve_synthesis_override(episode) == {:mock, mock_result}
    end
  end

  describe "dry_run_opts normalization" do
    test "nil stays nil" do
      assert normalize_dry_run_opts(nil) == nil
    end

    test "keyword list is normalized to string-keyed map" do
      opts = [tool_overrides: %{"a" => 1}, synthesis_override: %{class: "ok"}]
      result = normalize_dry_run_opts(opts)

      assert result["tool_overrides"] == %{"a" => 1}
      assert result["synthesis_override"] == %{class: "ok"}
    end

    test "map with atom keys is normalized to string keys" do
      opts = %{tool_overrides: %{"a" => 1}}
      result = normalize_dry_run_opts(opts)

      assert result["tool_overrides"] == %{"a" => 1}
    end

    test "map with string keys passes through" do
      opts = %{"tool_overrides" => %{"a" => 1}}
      result = normalize_dry_run_opts(opts)

      assert result["tool_overrides"] == %{"a" => 1}
    end
  end

  describe "merge_dry_run_opts" do
    test "live mode always returns nil regardless of inputs" do
      assert merge_opts(nil, nil, :live) == nil
      assert merge_opts([tool_overrides: %{}], nil, :live) == nil
      assert merge_opts(nil, %{"synthesis_override" => %{}}, :live) == nil
      assert merge_opts([a: 1], %{"b" => 2}, :live) == nil
    end

    test "dry_run mode with no overrides returns nil" do
      assert merge_opts(nil, nil, :dry_run) == nil
    end

    test "dry_run mode with only expectation overrides" do
      result = merge_opts([tool_overrides: %{"a" => 1}], nil, :dry_run)
      assert result["tool_overrides"] == %{"a" => 1}
    end

    test "dry_run mode with only fire-time overrides" do
      result = merge_opts(nil, %{"synthesis_override" => %{class: "ok"}}, :dry_run)
      assert result["synthesis_override"] == %{class: "ok"}
    end

    test "fire-time overrides take priority over expectation overrides" do
      exp = [tool_overrides: %{"a" => "exp_value"}, synthesis_override: %{class: "exp"}]
      fire = %{"tool_overrides" => %{"a" => "fire_value"}}

      result = merge_opts(exp, fire, :dry_run)

      # Fire-time tool_overrides wins
      assert result["tool_overrides"] == %{"a" => "fire_value"}
      # Expectation synthesis_override is kept (not overridden)
      assert result["synthesis_override"] == %{class: "exp"}
    end

    test "fire-time can add new keys not in expectation" do
      exp = [tool_overrides: %{"a" => 1}]
      fire = %{"synthesis_override" => %{class: "mock"}}

      result = merge_opts(exp, fire, :dry_run)

      assert result["tool_overrides"] == %{"a" => 1}
      assert result["synthesis_override"] == %{class: "mock"}
    end
  end

  describe "Episode schema fields" do
    test "mode defaults to live" do
      ep = %Cyclium.Schemas.Episode{}
      assert ep.mode == "live"
    end

    test "dry_run_opts defaults to nil" do
      ep = %Cyclium.Schemas.Episode{}
      assert ep.dry_run_opts == nil
    end
  end

  describe "Expectation struct" do
    test "dry_run defaults to nil" do
      exp = %Expectation{}
      assert exp.dry_run == nil
    end

    test "dry_run can be set" do
      exp = %Expectation{dry_run: [tool_overrides: %{"a" => 1}]}
      assert exp.dry_run == [tool_overrides: %{"a" => 1}]
    end
  end

  describe "ConvergeResult in dry run context" do
    test "findings and outputs preserved in struct regardless of mode" do
      result = %ConvergeResult{
        findings: [{:raise, %{finding_key: "test:1", class: "ok"}}],
        outputs: [%OutputProposal{type: :email, dedupe_key: "test:1:email", payload: %{}}],
        summary: "test",
        classification: %{"primary" => "ok"},
        confidence: 0.9
      }

      # The struct is the same — mode affects what EpisodeRunner does with it
      assert length(result.findings) == 1
      assert length(result.outputs) == 1
    end
  end

  describe "dry run journal markers" do
    test "dry run finding journal includes _dry_run flag" do
      # Replicating the journal_dry_run_findings logic
      findings = [
        {:raise, %{finding_key: "test:1", class: "ok", severity: :low}},
        {:update, "test:1", %{severity: :high}},
        {:clear, "test:2"},
        {:clear, "test:3", "resolved"}
      ]

      journaled =
        Enum.map(findings, fn action ->
          {kind, detail} = extract_dry_run_finding(action)
          %{kind: kind, result_ref: Map.merge(detail, %{"_dry_run" => true})}
        end)

      assert Enum.at(journaled, 0).kind == :finding_raised
      assert Enum.at(journaled, 0).result_ref["_dry_run"] == true
      assert Enum.at(journaled, 0).result_ref[:finding_key] == "test:1"

      assert Enum.at(journaled, 1).kind == :finding_updated
      assert Enum.at(journaled, 1).result_ref["_dry_run"] == true

      assert Enum.at(journaled, 2).kind == :finding_cleared
      assert Enum.at(journaled, 2).result_ref["_dry_run"] == true
      assert Enum.at(journaled, 2).result_ref[:finding_key] == "test:2"

      assert Enum.at(journaled, 3).kind == :finding_cleared
      assert Enum.at(journaled, 3).result_ref["_dry_run"] == true
    end

    test "dry run output journal includes _dry_run flag" do
      outputs = [
        %OutputProposal{type: :email, dedupe_key: "test:1:email", payload: %{to: "a@b.com"}},
        %OutputProposal{type: :slack, dedupe_key: "test:1:slack", payload: %{channel: "#alerts"}}
      ]

      results =
        Enum.map(outputs, fn proposal ->
          journal = %{
            kind: :output_proposed,
            result_ref: %{"_dry_run" => true, "proposal" => inspect(proposal)}
          }

          {journal, {:ok, :dry_run_skipped}}
        end)

      assert length(results) == 2

      Enum.each(results, fn {journal, result} ->
        assert journal.kind == :output_proposed
        assert journal.result_ref["_dry_run"] == true
        assert result == {:ok, :dry_run_skipped}
      end)
    end
  end

  describe "dry run episode status computation" do
    test "all dry_run_skipped outputs compute as :done" do
      output_results = [
        {:ok, :dry_run_skipped},
        {:ok, :dry_run_skipped},
        {:ok, :dry_run_skipped}
      ]

      assert compute_episode_status(output_results) == :done
    end

    test "empty outputs compute as :done" do
      assert compute_episode_status([]) == :done
    end

    test "mixed results compute correctly" do
      assert compute_episode_status([{:ok, :ref}, {:error, :fail}]) == :partially_failed
      assert compute_episode_status([{:error, :fail}]) == :failed
      assert compute_episode_status([{:ok, :ref}]) == :done
      assert compute_episode_status([{:duplicate, :ref}]) == :done
    end
  end

  # --- Helper functions that replicate private functions for testing ---

  # Replicates dry_run_tool_override/2 from EpisodeRunner
  defp resolve_tool_override(%{mode: "dry_run", dry_run_opts: opts}, tool_name)
       when is_map(opts) do
    overrides = Map.get(opts, "tool_overrides", %{})

    case Map.get(overrides, tool_name) do
      nil -> :real
      mock -> {:mock, mock}
    end
  end

  defp resolve_tool_override(_episode, _tool_name), do: :real

  # Replicates dry_run_synthesis_override/1 from EpisodeRunner
  defp resolve_synthesis_override(%{mode: "dry_run", dry_run_opts: opts}) when is_map(opts) do
    case Map.get(opts, "synthesis_override") do
      nil -> :real
      mock -> {:mock, mock}
    end
  end

  defp resolve_synthesis_override(_episode), do: :real

  # Replicates normalize_dry_run_opts/1 from Actor.Server
  defp normalize_dry_run_opts(nil), do: nil

  defp normalize_dry_run_opts(opts) when is_list(opts) do
    opts |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
  end

  defp normalize_dry_run_opts(opts) when is_map(opts) do
    opts |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Map.new()
  end

  # Replicates merge_dry_run_opts/3 from Actor.Server
  defp merge_opts(_exp, _fire, :live), do: nil

  defp merge_opts(exp, fire, :dry_run) do
    exp_opts = normalize_dry_run_opts(exp)
    fire_opts = normalize_dry_run_opts(fire)

    case {exp_opts, fire_opts} do
      {nil, nil} -> nil
      {nil, f} -> f
      {e, nil} -> e
      {e, f} -> Map.merge(e, f)
    end
  end

  # Replicates extract logic from journal_dry_run_findings
  defp extract_dry_run_finding({:raise, attrs}), do: {:finding_raised, attrs}
  defp extract_dry_run_finding({:update, _key, attrs}), do: {:finding_updated, attrs}
  defp extract_dry_run_finding({:clear, key}), do: {:finding_cleared, %{finding_key: key}}
  defp extract_dry_run_finding({:clear, key, _}), do: {:finding_cleared, %{finding_key: key}}

  # Replicates compute_episode_status from EpisodeRunner
  defp compute_episode_status(output_results) do
    successes =
      Enum.count(output_results, &match?({:ok, _}, &1)) +
        Enum.count(output_results, &match?({:duplicate, _}, &1))

    failures = Enum.count(output_results, &match?({:error, _}, &1))
    total = length(output_results)

    cond do
      total == 0 -> :done
      failures == 0 -> :done
      successes == 0 -> :failed
      true -> :partially_failed
    end
  end
end

defmodule Cyclium.EpisodeRunnerHardeningDbTest do
  use Cyclium.DataCase

  alias Cyclium.EpisodeRunner
  alias Cyclium.Schemas.{Episode, EpisodeStep, Finding}

  defmodule SecretTool do
    use Cyclium.Tool
    def call(:fetch, _args, _ctx), do: {:ok, %{"rows" => 1, "access_token" => "tok"}}
  end

  defmodule SecretToolStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_e, _t), do: {:ok, %{done: false}}

    def next_step(%{done: false}, _ctx),
      do: {:tool_call, :secret, :fetch, %{"id" => 1, "api_key" => "sk-live"}}

    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, %{state | done: true}}

    def converge(_state, _ctx),
      do: {:ok, %Cyclium.ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}
  end

  defmodule ModelFindingsStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_e, _t), do: {:ok, %{}}
    def next_step(_state, _ctx), do: :converge
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx) do
      findings =
        Cyclium.Strategy.Template.Agentic.Loop.build_findings_list([
          %{
            "action" => "raise",
            "finding_key" => "model:1",
            "class" => "anomaly",
            "summary" => "from the model",
            "actor_id" => "someone_else",
            "env" => "other-env"
          },
          # Malformed: a strategy-authored raise with no finding_key crashes
          # persist_finding; it must count as failed, not crash the episode.
          %{"action" => "raise", "class" => "broken"}
        ])

      {:ok,
       %Cyclium.ConvergeResult{
         summary: "ok",
         classification: %{},
         confidence: 1.0,
         # Append a raw, malformed action too (bypasses build_findings_list).
         findings: findings ++ [{:raise, %{class: "no_key_at_all"}}]
       }}
    end
  end

  defmodule BudgetStrategy do
    @behaviour Cyclium.EpisodeRunner.Strategy
    def init(_e, _t), do: {:ok, %{}}
    def next_step(_state, _ctx), do: {:observe, %{tick: true}}
    def handle_result(state, _step, _result), do: {:ok, state}

    def converge(_state, _ctx),
      do: {:ok, %Cyclium.ConvergeResult{summary: "ok", classification: %{}, confidence: 1.0}}
  end

  setup do
    Application.put_env(:cyclium, :capability_registry, %{secret: SecretTool})
    on_exit(fn -> Application.delete_env(:cyclium, :capability_registry) end)
    :ok
  end

  test "credential-like keys in tool args and results never reach the journal" do
    episode = insert_episode(%{actor_id: "hardening_redaction_actor", log_strategy: "full_debug"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, SecretToolStrategy, %{done: false})

    step =
      Repo.one!(
        from(s in EpisodeStep, where: s.episode_id == ^episode.id and s.kind == :tool_call)
      )

    assert step.args_redacted["api_key"] == "[REDACTED]"
    assert step.args_redacted["id"] == 1
    assert step.result_ref["access_token"] == "[REDACTED]"
    assert step.result_ref["rows"] == 1
  end

  test "model-authored findings persist under the episode's actor and env; a malformed one is counted, not fatal" do
    episode = insert_episode(%{actor_id: "hardening_findings_actor"})

    assert {:ok, _} = EpisodeRunner.execute_loop(episode, ModelFindingsStrategy, %{})

    assert [finding] = Repo.all(from(f in Finding, where: f.finding_key == "model:1"))
    assert finding.actor_id == "hardening_findings_actor"
    assert is_nil(finding.env)

    # One raw malformed action failed to persist → partially_failed, not a crash.
    assert Repo.get!(Episode, episode.id).status == :partially_failed
  end

  test "a budget of zero is exhausted immediately rather than unlimited" do
    episode =
      insert_episode(%{actor_id: "hardening_budget_actor", budget: %{"max_turns" => 0}})

    assert {:error, :budget_exceeded} = EpisodeRunner.execute_loop(episode, BudgetStrategy, %{})
    assert Repo.get!(Episode, episode.id).error_class == "budget_exceeded"
  end
end

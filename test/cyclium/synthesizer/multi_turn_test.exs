defmodule Cyclium.Synthesizer.MultiTurnTest do
  @moduledoc """
  A client with `chat_with_messages/4` gets the episode's transcript: each call
  sends every earlier message unchanged, then the results of the calls the
  last reply made, answered by id.
  """
  use ExUnit.Case, async: false

  alias Cyclium.Strategy.Template.Interactive
  alias Cyclium.Synthesizer.Interactive, as: Synth

  # Replies in order from `:__turns_replies__`, recording each call's messages.
  defmodule TurnsLLM do
    @behaviour Cyclium.Synthesizer.Interactive.LLM

    @impl true
    def chat(_system, _user, _opts), do: {:ok, "unused"}

    @impl true
    def chat_with_messages(_system, messages, _tools, opts) do
      calls = Application.get_env(:cyclium, :__turns_calls__, [])
      Application.put_env(:cyclium, :__turns_calls__, calls ++ [{messages, opts}])

      [reply | rest] = Application.get_env(:cyclium, :__turns_replies__)
      Application.put_env(:cyclium, :__turns_replies__, rest)
      {:ok, reply}
    end
  end

  # A client with only the native single-message contract.
  defmodule NativeOnlyLLM do
    @behaviour Cyclium.Synthesizer.Interactive.LLM

    @impl true
    def chat(_system, _user, _opts), do: {:ok, "unused"}

    @impl true
    def chat_with_native_tools(_system, user, _tools, _opts) do
      Application.put_env(:cyclium, :__native_user__, user)
      {:ok, %{tool_calls: [], text: "done"}}
    end
  end

  # The plan gate admits only calls whose tool and action exist as atoms.
  @call_atoms [:lookup_user, :get, :list]

  setup do
    assert length(@call_atoms) == 3
    prev = Application.get_env(:cyclium, :interactive_llm)
    Application.put_env(:cyclium, :interactive_llm, TurnsLLM)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyclium, :interactive_llm, prev),
        else: Application.delete_env(:cyclium, :interactive_llm)

      for key <- [:__turns_calls__, :__turns_replies__, :__native_user__],
          do: Application.delete_env(:cyclium, key)
    end)

    :ok
  end

  defp replies(list), do: Application.put_env(:cyclium, :__turns_replies__, list)
  defp calls, do: Application.get_env(:cyclium, :__turns_calls__, [])

  defp tool_reply(id, action, opts \\ []) do
    call = %{id: id, name: "lookup_user__#{action}", input: %{"n" => id}}

    reply = %{
      tool_calls: [call],
      text: "",
      usage: %{input_tokens: 1, output_tokens: 1}
    }

    if Keyword.get(opts, :message, true) do
      Map.put(reply, :message, %{
        "role" => "assistant",
        "content" => [
          %{"type" => "thinking", "thinking" => "…", "signature" => "sig-#{id}"},
          %{"type" => "tool_use", "id" => id, "name" => call.name, "input" => call.input}
        ]
      })
    else
      Map.delete(reply, :message)
    end
  end

  defp text_reply(text),
    do: %{tool_calls: [], text: text, message: %{"role" => "assistant", "content" => []}}

  defp state(config \\ %{}) do
    %{
      phase: :interpret,
      strategy_config:
        Map.merge(
          %{
            "allowed_tool_signatures" => [
              %{
                "name" => "lookup_user",
                "side_effect" => "read",
                "actions" => [%{"name" => "get"}, %{"name" => "list"}]
              }
            ]
          },
          config
        ),
      message: "who is user 7?",
      principal: %{"id" => "u1"},
      history: [],
      conversation_id: nil,
      conversation: nil,
      goal: nil,
      gathered_context: %{history: []},
      action_plan: nil,
      plan_hash: nil,
      execution_results: [],
      current_step_index: 0,
      deny_reason: nil,
      explanation: nil,
      budget_exhausted: false
    }
  end

  # Run the loop until it converges, executing every tool call with `tool_result`.
  defp run(state, tool_result \\ fn _action -> {:ok, %{"name" => "Ada"}} end) do
    case Interactive.next_step(state, %{}) do
      :converge ->
        state

      {:synthesize, prompt} ->
        {:ok, result} = Synth.synthesize(prompt, %{})
        {:ok, next} = Interactive.handle_result(state, %{kind: :synthesis}, {:ok, result})
        run(next, tool_result)

      {:observe, data} ->
        {:ok, next} = Interactive.handle_result(state, %{}, {:ok, data})
        run(next, tool_result)

      {:tool_call, _tool, action, _args} ->
        {:ok, next} = Interactive.handle_result(state, %{}, tool_result.(action))
        run(next, tool_result)
    end
  end

  test "each call sends the transcript so far, then the results answered by id" do
    replies([tool_reply("toolu_1", "get"), tool_reply("toolu_2", "list"), text_reply("Ada.")])

    final = run(state())

    assert final.explanation == "Ada."
    assert [{first, _}, {second, _}, {third, _}] = calls()

    assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => head}]}] = first
    assert head =~ "who is user 7?"

    # Append-only: each call's messages lead the next call's.
    assert Enum.take(second, length(first)) == first
    assert Enum.take(third, length(second)) == second

    # The reply is replayed as returned, thinking block and all.
    assert %{"role" => "assistant", "content" => [%{"signature" => "sig-toolu_1"} | _]} =
             Enum.at(second, 1)

    assert %{"role" => "user", "content" => [result]} = List.last(second)
    assert result["type"] == "tool_result"
    assert result["tool_use_id"] == "toolu_1"
    assert result["is_error"] == false
    assert result["content"] =~ "<<<TOOL_RESULT lookup_user.get"
    assert result["content"] =~ ~s({"name":"Ada"})

    assert %{"content" => [%{"tool_use_id" => "toolu_2"}]} = List.last(third)
    assert length(final.transcript) == 6
  end

  test "several calls in one reply are answered in one turn, in order and in full" do
    calls = [
      %{id: "toolu_a", name: "lookup_user__get", input: %{}},
      %{id: "toolu_b", name: "lookup_user__list", input: %{}}
    ]

    two = %{
      tool_calls: calls,
      text: "",
      message: %{
        "role" => "assistant",
        "content" =>
          Enum.map(
            calls,
            &%{"type" => "tool_use", "id" => &1.id, "name" => &1.name, "input" => %{}}
          )
      }
    }

    replies([two, text_reply("Both.")])

    # A window of one would stub the older result in a single-message prompt;
    # a transcript sends each result once, so it gets both in full.
    final =
      run(state(%{"tool_result_window" => 1}), fn action ->
        {:ok, %{"action" => to_string(action)}}
      end)

    assert final.explanation == "Both."
    assert [_, {second, _}] = calls()
    assert %{"role" => "user", "content" => [a, b]} = List.last(second)
    assert a["tool_use_id"] == "toolu_a"
    assert a["content"] =~ ~s("action":"get")
    refute a["content"] =~ "Omitted"
    assert b["tool_use_id"] == "toolu_b"
    assert b["content"] =~ ~s("action":"list")
  end

  test "a failed tool's result is sent as an error" do
    replies([tool_reply("toolu_1", "get"), text_reply("It failed.")])

    run(state(), fn _ -> {:error, :not_found} end)

    assert [_, {second, _}] = calls()
    assert %{"content" => [%{"is_error" => true, "content" => content}]} = List.last(second)
    assert content =~ "not_found"
  end

  test "a reply without a message gets one built from its text and calls" do
    replies([tool_reply("toolu_1", "get", message: false), text_reply("Ada.")])

    run(state())

    assert [_, {second, _}] = calls()

    assert %{
             "role" => "assistant",
             "content" => [
               %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup_user__get"}
             ]
           } = Enum.at(second, 1)
  end

  test "a message whose call has no id ends the transcript; the next call is one message" do
    no_id =
      tool_reply("toolu_1", "get") |> Map.update!(:tool_calls, fn [c] -> [Map.delete(c, :id)] end)

    replies([no_id, text_reply("Ada.")])

    final = run(state())

    assert [_, {second, opts}] = calls()
    assert [%{"role" => "user", "content" => blocks}] = second
    assert Enum.map_join(blocks, & &1["text"]) =~ "<<<TOOL_RESULT lookup_user.get"
    assert is_list(opts[:user_blocks])
    assert final.transcript == []
  end

  test "multi_turn: false keeps the single-message path" do
    replies([tool_reply("toolu_1", "get"), text_reply("Ada.")])

    run(state(%{"multi_turn" => false}))

    assert [{first, _}, {second, _}] = calls()
    assert [%{"role" => "user"}] = first
    assert [%{"role" => "user"}] = second
  end

  test "a client without chat_with_messages/4 is unaffected" do
    Application.put_env(:cyclium, :interactive_llm, NativeOnlyLLM)

    final = run(state())

    assert final.action_plan.explanation == "done"
    assert final.transcript == []
    assert Application.get_env(:cyclium, :__native_user__) =~ "who is user 7?"
  end
end

defmodule Cyclium.Synthesizer.InteractiveSynthesizerTest do
  use ExUnit.Case, async: false

  alias Cyclium.Synthesizer.Interactive, as: Synth

  # A canned LLM client: returns whatever text the current test stashed in the
  # application env, so we can drive the synthesizer's JSON-extraction path with
  # specific model outputs.
  defmodule CannedLLM do
    @behaviour Cyclium.Synthesizer.Interactive.LLM

    @impl true
    def chat(_system, _user, _opts) do
      {:ok, Application.get_env(:cyclium, :__canned_llm_text__, "{}")}
    end
  end

  # Implements both contracts so we can exercise the native path and the
  # native-mode-but-falls-back-to-text case.
  defmodule NativeLLM do
    @behaviour Cyclium.Synthesizer.Interactive.LLM

    @impl true
    def chat(_system, _user, _opts) do
      {:ok, Application.get_env(:cyclium, :__canned_llm_text__, "{}")}
    end

    @impl true
    def chat_with_native_tools(_system, _user, tools, _opts) do
      Application.put_env(:cyclium, :__last_native_tools__, tools)
      Application.get_env(:cyclium, :__canned_native__, {:ok, %{tool_calls: [], text: ""}})
    end
  end

  defp tool_menu do
    [
      %{
        name: "episode_query",
        side_effect: "read",
        actions: [
          %{
            "name" => "list_episodes",
            "description" => "List episodes",
            "args" => %{"limit" => "max rows"}
          }
        ]
      }
    ]
  end

  defp interpret_native(canned_native, opts \\ []) do
    Application.put_env(:cyclium, :interactive_llm, NativeLLM)
    Application.put_env(:cyclium, :__canned_native__, canned_native)

    Synth.synthesize(
      %{
        task: :interpret_intent,
        message: "hi",
        tool_mode: :native,
        tool_menu: Keyword.get(opts, :tool_menu, tool_menu())
      },
      %{}
    )
  end

  setup do
    prev_llm = Application.get_env(:cyclium, :interactive_llm)
    Application.put_env(:cyclium, :interactive_llm, CannedLLM)

    on_exit(fn ->
      if prev_llm,
        do: Application.put_env(:cyclium, :interactive_llm, prev_llm),
        else: Application.delete_env(:cyclium, :interactive_llm)

      Application.delete_env(:cyclium, :__canned_llm_text__)
      Application.delete_env(:cyclium, :__canned_native__)
      Application.delete_env(:cyclium, :__last_native_tools__)
    end)

    :ok
  end

  defp canned(text), do: Application.put_env(:cyclium, :__canned_llm_text__, text)

  defp interpret(text) do
    canned(text)
    Synth.synthesize(%{task: :interpret_intent, message: "hi"}, %{})
  end

  describe "extract_json/1 (decode-first, normalize-as-fallback)" do
    test "preserves smart quotes that appear inside a valid string value" do
      # gpt-5 emits curly quotes inside *prose* (a valid JSON string value).
      # Unconditional quote-normalization would inject unescaped quotes and break
      # decode, dumping the raw envelope into `explanation`. Decode-first avoids it.
      payload =
        ~s({"kind": "explain_only", "risk": "low", "why": "response", "explanation": "Here is “what’s” happening"})

      assert {:ok, map} = interpret(payload)
      assert map["kind"] == "explain_only"
      assert map["explanation"] == "Here is “what’s” happening"
      # It must NOT have fallen back to dumping the raw envelope as the explanation.
      refute map["explanation"] =~ "kind"
    end

    test "still recovers when the structural quotes themselves are curly" do
      # The normalize fallback must still fire for models that emit the *structural*
      # JSON quotes as curly (the original failure mode the normalizer guards).
      payload =
        "{“kind”: “explain_only”, “risk”: “low”, “why”: “r”, “explanation”: “hello”}"

      assert {:ok, map} = interpret(payload)
      assert map["kind"] == "explain_only"
      assert map["explanation"] == "hello"
    end

    test "extracts a valid envelope wrapped in prose and a code fence" do
      payload = """
      Sure, here you go:
      ```json
      {"kind": "explain_only", "risk": "low", "why": "r", "explanation": "ok"}
      ```
      """

      assert {:ok, map} = interpret(payload)
      assert map["explanation"] == "ok"
    end
  end

  describe "model annotation" do
    test "tags the result with the configured model for metadata/telemetry" do
      prev_opts = Application.get_env(:cyclium, :interactive_llm_opts)
      Application.put_env(:cyclium, :interactive_llm_opts, model: "test-model-x")

      on_exit(fn ->
        if prev_opts,
          do: Application.put_env(:cyclium, :interactive_llm_opts, prev_opts),
          else: Application.delete_env(:cyclium, :interactive_llm_opts)
      end)

      payload = ~s({"kind": "explain_only", "risk": "low", "why": "r", "explanation": "ok"})

      assert {:ok, map} = interpret(payload)
      assert map[:model] == "test-model-x"
    end

    test "leaves the result untagged when no model is configured" do
      payload = ~s({"kind": "explain_only", "risk": "low", "why": "r", "explanation": "ok"})

      assert {:ok, map} = interpret(payload)
      refute Map.has_key?(map, :model)
    end
  end

  describe "native tool calling" do
    test "a single tool_use becomes a tool_call envelope (tool/action split)" do
      native =
        {:ok,
         %{
           tool_calls: [%{name: "episode_query__list_episodes", input: %{"limit" => "5"}}],
           text: nil,
           model: "claude-native-x"
         }}

      assert {:ok, map} = interpret_native(native)
      assert map["kind"] == "tool_call"
      assert map["tool"]["tool"] == "episode_query"
      assert map["tool"]["action"] == "list_episodes"
      assert map["tool"]["args"] == %{"limit" => "5"}
      # actual model returned by the adapter is preserved for metadata/telemetry
      assert map[:model] == "claude-native-x"
    end

    test "no tool_use becomes an explain_only envelope from the text" do
      native = {:ok, %{tool_calls: [], text: "here is the answer"}}

      assert {:ok, map} = interpret_native(native)
      assert map["kind"] == "explain_only"
      assert map["explanation"] == "here is the answer"
    end

    test "multiple tool_use blocks become a multi_tool_plan" do
      native =
        {:ok,
         %{
           tool_calls: [
             %{name: "episode_query__list_episodes", input: %{"limit" => "5"}},
             %{name: "episode_query__list_episodes", input: %{"limit" => "10"}}
           ],
           text: nil
         }}

      assert {:ok, map} = interpret_native(native)
      assert map["kind"] == "multi_tool_plan"
      assert length(map["steps"]) == 2
      assert Enum.all?(map["steps"], &(&1["tool"] == "episode_query"))
    end

    test "builds flat provider tool schemas from the tool menu" do
      interpret_native({:ok, %{tool_calls: [], text: "ok"}})

      tools = Application.get_env(:cyclium, :__last_native_tools__)
      assert [%{name: "episode_query__list_episodes"} = tool] = tools
      # Args carry their hint as a description but DON'T force a type, so the model
      # can pass structured values (arrays/objects), not just strings.
      assert tool.input_schema["properties"]["limit"]["description"] == "max rows"
      refute Map.has_key?(tool.input_schema["properties"]["limit"], "type")
    end

    test "with no tools to offer, replies as explain_only via the text path" do
      Application.put_env(:cyclium, :__canned_llm_text__, "just a plain answer")

      assert {:ok, map} = interpret_native({:ok, %{tool_calls: []}}, tool_menu: [])
      assert map["kind"] == "explain_only"
      assert map["explanation"] == "just a plain answer"
    end

    test "defaults to native (no tool_mode set) when the client supports it" do
      Application.put_env(:cyclium, :interactive_llm, NativeLLM)

      Application.put_env(
        :cyclium,
        :__canned_native__,
        {:ok, %{tool_calls: [%{name: "episode_query__list_episodes", input: %{}}], text: nil}}
      )

      result =
        Synth.synthesize(
          %{task: :interpret_intent, message: "hi", tool_menu: tool_menu()},
          %{}
        )

      assert {:ok, %{"kind" => "tool_call"}} = result
    end

    test "tool_mode: :text opts out of native even with a native-capable client" do
      Application.put_env(:cyclium, :interactive_llm, NativeLLM)

      Application.put_env(
        :cyclium,
        :__canned_llm_text__,
        ~s({"kind": "explain_only", "risk": "low", "why": "r", "explanation": "text path"})
      )

      result =
        Synth.synthesize(
          %{task: :interpret_intent, message: "hi", tool_mode: :text, tool_menu: tool_menu()},
          %{}
        )

      assert {:ok, %{"explanation" => "text path"}} = result
    end

    test "falls back to the text envelope when the client lacks native support" do
      # CannedLLM implements only chat/3 — native mode must degrade to text.
      Application.put_env(:cyclium, :interactive_llm, CannedLLM)

      payload = ~s({"kind": "explain_only", "risk": "low", "why": "r", "explanation": "via text"})
      Application.put_env(:cyclium, :__canned_llm_text__, payload)

      result =
        Synth.synthesize(
          %{task: :interpret_intent, message: "hi", tool_mode: :native, tool_menu: tool_menu()},
          %{}
        )

      assert {:ok, map} = result
      assert map["explanation"] == "via text"
    end
  end
end

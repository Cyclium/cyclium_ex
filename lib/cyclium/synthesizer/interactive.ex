defmodule Cyclium.Synthesizer.Interactive do
  @moduledoc """
  Default synthesizer for interactive actors.

  Handles the full prompt-building, LLM calling, and JSON-parsing loop so that
  consuming apps only need to provide an LLM client module.

  ## LLM Client behaviour

  The LLM client must implement `c:Cyclium.Synthesizer.Interactive.LLM.chat/3`:

      defmodule MyApp.Anthropic do
        @behaviour Cyclium.Synthesizer.Interactive.LLM

        @impl true
        def chat(system_prompt, user_message, opts) do
          # call your LLM provider
          {:ok, response_text}
        end
      end

  ## Configuration

  Set the LLM client in the actor definition or application config:

      # Per-actor (in actor module):
      synthesizer({Cyclium.Synthesizer.Interactive, llm: MyApp.Anthropic})

      # Or globally:
      config :cyclium, :interactive_llm, MyApp.Anthropic
  """

  @behaviour Cyclium.Synthesizer

  require Logger

  defmodule LLM do
    @moduledoc """
    Behaviour for LLM clients used by the Interactive synthesizer.
    """

    @callback chat(system_prompt :: String.t(), user_message :: String.t(), opts :: keyword()) ::
                {:ok, String.t()}
                | {:error, :no_api_key}
                | {:error, {atom(), term()}}
  end

  @impl true
  def synthesize(prompt_ctx, episode_ctx) do
    llm_client = resolve_llm_client(episode_ctx)
    llm_opts = resolve_llm_opts(episode_ctx)
    system_prompt = prompt_ctx[:system_prompt] || default_system_prompt()

    case prompt_ctx[:task] do
      :summarize_results ->
        synthesize_summary(llm_client, llm_opts, system_prompt, prompt_ctx)

      _ ->
        synthesize_interpret(llm_client, llm_opts, system_prompt, prompt_ctx)
    end
  end

  @impl true
  def estimate_tokens(prompt_ctx) do
    msg = prompt_ctx[:message] || ""
    context = prompt_ctx[:context] || %{}
    history_size = length(context[:prior_summaries] || []) * 100
    div(String.length(msg) + history_size + 500, 4)
  end

  # --- Interpret ---

  defp synthesize_interpret(llm_client, llm_opts, system_prompt, prompt_ctx) do
    user_message = build_user_message(prompt_ctx)

    case llm_client.chat(system_prompt, user_message, chat_opts(llm_opts)) do
      {:ok, text} ->
        parse_json_response(text)

      {:error, :no_api_key} ->
        Logger.warning("[Interactive.Synthesizer] No API key — returning placeholder")
        fallback_response(prompt_ctx)

      {:error, {error_class, detail}} ->
        {:error, error_class, detail}
    end
  end

  # --- Summarize ---

  defp synthesize_summary(llm_client, llm_opts, system_prompt, prompt_ctx) do
    context = prompt_ctx[:context] || %{}

    user_message = """
    The user asked: #{prompt_ctx[:message]}

    A tool was executed: #{context[:tool_executed]}

    Tool results:
    #{context[:tool_results]}

    Based on these results, either:
    1. Summarize the data for the user:
       {"kind": "explain_only", "risk": "low", "why": "reason", "explanation": "YOUR SUMMARY HERE"}
    2. Or if you need to make another tool call to fulfill the user's request:
       {"kind": "tool_call", "risk": "low", "why": "reason", "tool": {"tool": "TOOL", "action": "ACTION", "args": {ARGS}}}
    """

    case llm_client.chat(system_prompt, user_message, chat_opts(llm_opts)) do
      {:ok, text} ->
        parse_json_response(text)

      {:error, :no_api_key} ->
        Logger.warning("[Interactive.Synthesizer] No API key — returning placeholder")
        {:ok, %{"explanation" => context[:tool_results] || "Tool executed successfully."}}

      {:error, {error_class, detail}} ->
        {:error, error_class, detail}
    end
  end

  # --- Prompt building ---

  defp build_user_message(prompt_ctx) do
    message = prompt_ctx[:message] || ""
    context = prompt_ctx[:context] || %{}
    tool_menu = prompt_ctx[:tool_menu] || []

    tools_desc =
      Enum.map_join(tool_menu, "\n", fn t ->
        actions_desc =
          case t[:actions] do
            actions when is_list(actions) and actions != [] ->
              details =
                Enum.map_join(actions, "\n", fn a ->
                  name = a["name"] || a[:name]
                  desc = a["description"] || a[:description] || ""
                  args = a["args"] || a[:args] || %{}

                  arg_keys =
                    case args do
                      m when is_map(m) and map_size(m) > 0 ->
                        " args: #{inspect(Map.keys(m))}"

                      _ ->
                        ""
                    end

                  "      * #{name}#{arg_keys} — #{desc}"
                end)

              "\n    actions:\n#{details}"

            _ ->
              ""
          end

        "  - #{t[:name]}: side_effect=#{t[:side_effect]}#{actions_desc}"
      end)

    history_desc =
      case context[:prior_summaries] do
        summaries when is_list(summaries) and summaries != [] ->
          summaries
          |> Enum.map_join("\n", fn s ->
            "  [#{s[:started_at] || s["started_at"]}] #{s[:summary] || s["summary"]}"
          end)
          |> then(&"## Conversation History\n#{&1}\n\n")

        _ ->
          ""
      end

    findings_desc =
      case context[:findings] do
        findings when is_list(findings) and findings != [] ->
          findings
          |> Enum.map_join("\n", fn f ->
            key = Map.get(f, :finding_key, nil) || Map.get(f, "finding_key", "")
            summary = Map.get(f, :summary, nil) || Map.get(f, "summary", "")
            "  - #{key}: #{summary}"
          end)
          |> then(&"## Active Findings\n#{&1}\n\n")

        _ ->
          ""
      end

    collected_desc =
      case context[:collected_fields] do
        fields when is_map(fields) and fields != %{} ->
          "## Collected Fields\n#{inspect(fields)}\n\n"

        _ ->
          ""
      end

    """
    #{history_desc}#{findings_desc}#{collected_desc}## Available Tools
    #{tools_desc}

    ## User Message
    #{message}

    Respond with a JSON object following the ActionPlan schema. Do NOT wrap in markdown code fences.
    """
  end

  # --- JSON parsing ---

  defp parse_json_response(text) do
    case extract_json(text) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> explain_only(text)
        end

      _ ->
        explain_only(text)
    end
  end

  defp explain_only(text) do
    {:ok,
     %{"kind" => "explain_only", "risk" => "low", "why" => "response", "explanation" => text}}
  end

  # Pull a decodable JSON object out of a model response that may wrap it in
  # prose, code fences, smart/curly quotes, or trailing extra objects. Returns
  # the first balanced `{...}` object (with quotes normalized), or nil if none.
  defp extract_json(text) do
    text
    |> String.trim()
    |> strip_code_fence()
    |> normalize_quotes()
    |> first_json_object()
  end

  defp strip_code_fence(text) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?\s*```/s, text) do
      [_, inner] -> String.trim(inner)
      nil -> text
    end
  end

  # Models sometimes emit the JSON envelope with curly/smart quotes, which break
  # Jason. Normalize them to straight quotes before decoding.
  defp normalize_quotes(text) do
    text
    |> String.replace(["“", "”", "„", "‟"], "\"")
    |> String.replace(["‘", "’", "‚", "‛"], "'")
  end

  # First balanced `{...}` object in the text, respecting string literals and
  # escapes, so leading prose or trailing extra objects don't break decoding.
  defp first_json_object(text) do
    case :binary.match(text, "{") do
      :nomatch ->
        nil

      {pos, _} ->
        text |> binary_part(pos, byte_size(text) - pos) |> balanced_object([], 0, false, false)
    end
  end

  defp balanced_object(<<>>, _acc, _depth, _in_str, _esc), do: nil

  defp balanced_object(<<c::utf8, rest::binary>>, acc, depth, in_str, esc) do
    acc = [acc, <<c::utf8>>]

    cond do
      esc -> balanced_object(rest, acc, depth, in_str, false)
      in_str and c == ?\\ -> balanced_object(rest, acc, depth, in_str, true)
      in_str and c == ?" -> balanced_object(rest, acc, depth, false, false)
      in_str -> balanced_object(rest, acc, depth, in_str, false)
      c == ?" -> balanced_object(rest, acc, depth, true, false)
      c == ?{ -> balanced_object(rest, acc, depth + 1, in_str, false)
      c == ?} and depth == 1 -> IO.iodata_to_binary(acc)
      c == ?} -> balanced_object(rest, acc, depth - 1, in_str, false)
      true -> balanced_object(rest, acc, depth, in_str, false)
    end
  end

  defp fallback_response(prompt_ctx) do
    message = prompt_ctx[:message] || ""

    {:ok,
     %{
       "kind" => "explain_only",
       "risk" => "low",
       "why" => "no_api_key",
       "explanation" =>
         "[No API key configured] I would analyze your request: #{String.slice(message, 0, 200)}"
     }}
  end

  # --- LLM client resolution ---

  defp resolve_llm_client(episode_ctx) do
    # Check for {Cyclium.Synthesizer.Interactive, llm: MyModule} tuple config
    # stored as synthesizer opts in persistent_term, or fall back to app config
    actor_key = actor_key(episode_ctx)

    from_persistent =
      if actor_key do
        :persistent_term.get({:cyclium_interactive_llm, actor_key}, nil)
      end

    from_persistent ||
      Application.get_env(:cyclium, :interactive_llm) ||
      raise "No LLM client configured for Cyclium.Synthesizer.Interactive. " <>
              "Set config :cyclium, :interactive_llm, MyApp.LLMClient"
  end

  # Extra synthesizer opts (e.g. `model:`) declared on the actor —
  # `synthesizer({Cyclium.Synthesizer.Interactive, llm: Adapter, model: "..."})`
  # — forwarded to the LLM client's `chat/3` opts so a model can be chosen per
  # actor without a bespoke adapter. Falls back to app config, then none.
  defp resolve_llm_opts(episode_ctx) do
    actor_key = actor_key(episode_ctx)

    from_persistent =
      if actor_key do
        :persistent_term.get({:cyclium_synthesizer_opts, actor_key}, nil)
      end

    from_persistent || Application.get_env(:cyclium, :interactive_llm_opts, [])
  end

  # Per-call chat opts: a default output cap the synthesizer opts can override
  # (so e.g. `model:` flows through, and `max_tokens:` can be tuned per actor).
  defp chat_opts(llm_opts), do: Keyword.merge([max_tokens: 2048], llm_opts)

  defp actor_key(episode_ctx) do
    if episode_ctx[:actor_id] do
      try do
        String.to_existing_atom(to_string(episode_ctx[:actor_id]))
      rescue
        _ -> nil
      end
    end
  end

  defp default_system_prompt do
    """
    You are a helpful assistant. Respond with a valid JSON object matching the ActionPlan schema.

    For tool calls:
    {"kind": "tool_call", "risk": "low", "why": "reason", "tool": {"tool": "TOOL", "action": "ACTION", "args": {}}}

    For explanations:
    {"kind": "explain_only", "risk": "low", "why": "reason", "explanation": "your response"}
    """
  end
end

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

    `chat/3` is the text contract: the model replies with a JSON `ActionPlan`
    envelope as text, which the synthesizer parses.

    `chat_with_native_tools/4` is the optional **native** contract: tool
    signatures are passed to the provider as structured `tools`, and the model
    replies with validated `tool_use` blocks instead of a text envelope —
    removing the whole class of text-parse failures (smart quotes, dotted names,
    over-structured values). The synthesizer uses the native path **by default**
    whenever the configured client exports `chat_with_native_tools/4`; an actor
    opts out with `strategy_config: %{tool_mode: :text}`, and a client that
    doesn't implement the callback falls back to the text path automatically.
    Return shape:

        {:ok, %{
          tool_calls: [%{name: "tool__action", input: %{...}}],  # [] if none
          text: "assistant prose, if any",
          model: "model-id",   # optional
          usage: %{...}        # optional
        }}
    """

    @callback chat(system_prompt :: String.t(), user_message :: String.t(), opts :: keyword()) ::
                {:ok, String.t()}
                | {:error, :no_api_key}
                | {:error, {atom(), term()}}

    @callback chat_with_native_tools(
                system_prompt :: String.t(),
                user_message :: String.t(),
                tools :: [map()],
                opts :: keyword()
              ) ::
                {:ok, map()}
                | {:error, :no_api_key}
                | {:error, {atom(), term()}}

    @optional_callbacks chat_with_native_tools: 4
  end

  @impl true
  def synthesize(prompt_ctx, episode_ctx) do
    llm_client = resolve_llm_client(episode_ctx)
    llm_opts = resolve_llm_opts(episode_ctx)
    system_prompt = prompt_ctx[:system_prompt] || default_system_prompt()

    result =
      cond do
        native_tool_mode?(prompt_ctx, llm_client) ->
          synthesize_native(llm_client, llm_opts, system_prompt, prompt_ctx)

        prompt_ctx[:task] == :summarize_results ->
          synthesize_summary(llm_client, llm_opts, system_prompt, prompt_ctx)

        true ->
          synthesize_interpret(llm_client, llm_opts, system_prompt, prompt_ctx)
      end

    annotate_model(result, llm_opts[:model])
  end

  # Tag a successful result with the configured model so the episode runner can
  # record it on the episode/step `metadata` and the synthesis telemetry can
  # populate its `llm` span. `Map.put_new/3`, so the native path's *actual*
  # model (returned by `chat_with_native_tools/4`) takes precedence; the text
  # `chat/3` contract doesn't return one, so it falls back to the configured model.
  defp annotate_model({:ok, map}, model) when is_map(map) and is_binary(model) do
    {:ok, Map.put_new(map, :model, model)}
  end

  defp annotate_model(result, _model), do: result

  # --- Native (structured) tool calling ---

  # Native is the DEFAULT; an actor opts out with `tool_mode: :text`. Falls back
  # to the text-envelope path when the configured client doesn't implement
  # `chat_with_native_tools/4` — warning only when native was *explicitly*
  # requested, so an intentionally text-only client stays quiet.
  defp native_tool_mode?(prompt_ctx, llm_client) do
    mode = prompt_ctx[:tool_mode]

    cond do
      mode in [:text, "text"] ->
        false

      native_capable?(llm_client) ->
        true

      true ->
        if mode in [:native, "native"] do
          Logger.warning(
            "[Interactive.Synthesizer] tool_mode: :native but #{inspect(llm_client)} " <>
              "does not implement chat_with_native_tools/4 — using the text path"
          )
        end

        false
    end
  end

  defp native_capable?(llm_client) do
    Code.ensure_loaded?(llm_client) and function_exported?(llm_client, :chat_with_native_tools, 4)
  end

  # Pass the actor's tool signatures to the provider as structured `tools` and
  # read back validated tool_use blocks, then shape them into the SAME map the
  # text path produces — so the strategy's ActionPlan / validate / approve /
  # execute machinery is unchanged; only the fragile text envelope is gone.
  defp synthesize_native(llm_client, llm_opts, system_prompt, prompt_ctx) do
    tools = build_native_tools(prompt_ctx[:tool_menu] || [])

    user_message =
      case prompt_ctx[:task] do
        :summarize_results -> build_native_summary_message(prompt_ctx)
        _ -> build_native_user_message(prompt_ctx)
      end

    # Nothing to call (an actor with no tools): fall back to a plain text reply
    # and treat it as an explanation rather than sending an empty `tools` list.
    if tools == [] do
      synthesize_native_textonly(llm_client, llm_opts, system_prompt, user_message, prompt_ctx)
    else
      case llm_client.chat_with_native_tools(
             system_prompt,
             user_message,
             tools,
             chat_opts(llm_opts)
           ) do
        {:ok, %{} = resp} ->
          {:ok, native_envelope(resp)}

        {:error, :no_api_key} ->
          Logger.warning("[Interactive.Synthesizer] No API key — returning placeholder")
          native_fallback(prompt_ctx)

        {:error, {error_class, detail}} ->
          {:error, error_class, detail}
      end
    end
  end

  defp synthesize_native_textonly(llm_client, llm_opts, system_prompt, user_message, prompt_ctx) do
    case llm_client.chat(system_prompt, user_message, chat_opts(llm_opts)) do
      {:ok, text} ->
        {:ok,
         %{
           "kind" => "explain_only",
           "risk" => "low",
           "why" => "response",
           "explanation" => text
         }}

      {:error, :no_api_key} ->
        Logger.warning("[Interactive.Synthesizer] No API key — returning placeholder")
        native_fallback(prompt_ctx)

      {:error, {error_class, detail}} ->
        {:error, error_class, detail}
    end
  end

  defp native_fallback(%{task: :summarize_results} = prompt_ctx) do
    context = prompt_ctx[:context] || %{}
    {:ok, %{"explanation" => context[:tool_results] || "Tool executed successfully."}}
  end

  defp native_fallback(prompt_ctx), do: fallback_response(prompt_ctx)

  # Build provider-shaped tool schemas from cyclium's tool menu. cyclium models a
  # tool + action pair; native function-calling is flat, so each (tool, action)
  # becomes one native tool named `"<tool>__<action>"` (kept to the
  # `^[a-zA-Z0-9_-]+$` charset providers require), split back apart on return.
  defp build_native_tools(tool_menu) do
    Enum.flat_map(tool_menu, fn t ->
      tool_name = t[:name] || t["name"]
      side_effect = t[:side_effect] || t["side_effect"]

      case t[:actions] || t["actions"] do
        actions when is_list(actions) and actions != [] ->
          Enum.map(actions, fn a ->
            action_name = a["name"] || a[:name]
            desc = a["description"] || a[:description] || ""
            args = a["args"] || a[:args] || %{}

            %{
              name: "#{tool_name}__#{action_name}",
              description: native_description(desc, side_effect),
              input_schema: native_input_schema(args)
            }
          end)

        _ ->
          []
      end
    end)
  end

  defp native_description(desc, nil), do: desc
  defp native_description(desc, side_effect), do: "#{desc} (side_effect: #{side_effect})"

  defp native_input_schema(args) when is_map(args) and map_size(args) > 0 do
    props =
      Map.new(args, fn {k, hint} ->
        # cyclium signatures describe args with free-text hints, not JSON-Schema
        # types, so we DON'T constrain the type. Forcing "string" makes the model
        # stringify structured args — a `rows` array, a `headers` list — which then
        # fail tools that expect real arrays/objects (e.g. generate_csv → no_rows).
        # Carry the hint as the description and leave the type open.
        prop = if is_binary(hint), do: %{"description" => hint}, else: %{}
        {to_string(k), prop}
      end)

    %{"type" => "object", "properties" => props, "additionalProperties" => true}
  end

  defp native_input_schema(_), do: %{"type" => "object", "additionalProperties" => true}

  # Shape native tool_use blocks (or final text) into the text-path's envelope
  # map so `parse_action_plan` consumes it unchanged. One call → tool_call; many
  # → multi_tool_plan; none → explain_only.
  defp native_envelope(%{} = resp) do
    calls = resp[:tool_calls] || resp["tool_calls"] || []

    envelope =
      case Enum.map(calls, &native_tool_call/1) do
        [] ->
          text = resp[:text] || resp["text"] || ""
          %{"kind" => "explain_only", "risk" => "low", "why" => "response", "explanation" => text}

        [single] ->
          %{"kind" => "tool_call", "risk" => "low", "why" => "native tool call", "tool" => single}

        many ->
          %{
            "kind" => "multi_tool_plan",
            "risk" => "low",
            "why" => "native tool calls",
            "steps" => many
          }
      end

    case resp[:model] || resp["model"] do
      nil -> envelope
      model -> Map.put(envelope, :model, model)
    end
  end

  defp native_tool_call(call) do
    name = call[:name] || call["name"] || ""
    input = call[:input] || call["input"] || %{}
    {tool, action} = split_native_tool_name(name)
    %{"tool" => tool, "action" => action, "args" => input}
  end

  defp split_native_tool_name(name) do
    case String.split(name, "__", parts: 2) do
      [tool, action] -> {tool, action}
      [tool] -> {tool, nil}
    end
  end

  defp build_native_summary_message(prompt_ctx) do
    context = prompt_ctx[:context] || %{}

    """
    The user asked: #{prompt_ctx[:message]}

    A tool was executed: #{context[:tool_executed]}

    Tool results:
    #{context[:tool_results]}

    Summarize the results for the user, or call another tool if more data is needed.
    """
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

  # Text-path user message: context + a prose tool list + the instruction to
  # reply with the JSON ActionPlan envelope.
  defp build_user_message(prompt_ctx) do
    """
    #{build_context_section(prompt_ctx)}## Available Tools
    #{build_tools_desc(prompt_ctx[:tool_menu] || [])}

    ## User Message
    #{prompt_ctx[:message] || ""}

    Respond with a JSON object following the ActionPlan schema. Do NOT wrap in markdown code fences.
    """
  end

  # Native-path user message: the SAME context, but with NO prose tool list and
  # NO text-envelope instruction — the tools are given to the model structurally
  # (API `tools`) and it replies with native tool_use blocks or plain prose, not
  # a JSON envelope. Including the envelope instruction here makes the model emit
  # the envelope as text instead of calling tools.
  defp build_native_user_message(prompt_ctx) do
    """
    #{build_context_section(prompt_ctx)}## User Message
    #{prompt_ctx[:message] || ""}
    """
  end

  defp build_context_section(prompt_ctx) do
    context = prompt_ctx[:context] || %{}

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

    "#{history_desc}#{findings_desc}#{collected_desc}"
  end

  defp build_tools_desc(tool_menu) do
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
  # the first balanced `{...}` object, or nil if none.
  #
  # Decode-first / normalize-as-fallback: `normalize_quotes/1` is a recovery path
  # for models that emit the *structural* JSON quotes as curly. Applying it
  # unconditionally corrupts otherwise-valid JSON whose string *values*
  # legitimately contain smart quotes (gpt-5 emits curly quotes inside prose,
  # e.g. inside an `explanation`), injecting unescaped quotes and breaking decode.
  # So try the payload as-is first, and only normalize when it doesn't decode.
  defp extract_json(text) do
    stripped = text |> String.trim() |> strip_code_fence()

    with obj when is_binary(obj) <- first_json_object(stripped),
         {:ok, _} <- Jason.decode(obj) do
      obj
    else
      _ -> stripped |> normalize_quotes() |> first_json_object()
    end
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

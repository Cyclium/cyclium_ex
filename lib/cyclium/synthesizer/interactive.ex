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
    system_prompt = prompt_ctx[:system_prompt] || default_system_prompt()

    case prompt_ctx[:task] do
      :summarize_results ->
        synthesize_summary(llm_client, system_prompt, prompt_ctx)

      _ ->
        synthesize_interpret(llm_client, system_prompt, prompt_ctx)
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

  defp synthesize_interpret(llm_client, system_prompt, prompt_ctx) do
    user_message = build_user_message(prompt_ctx)

    case llm_client.chat(system_prompt, user_message, max_tokens: 2048) do
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

  defp synthesize_summary(llm_client, system_prompt, prompt_ctx) do
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

    case llm_client.chat(system_prompt, user_message, max_tokens: 2048) do
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
        "  - #{t[:name]}: side_effect=#{t[:side_effect]}"
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
    json_str = extract_json(text)

    case Jason.decode(json_str) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        {:ok,
         %{
           "kind" => "explain_only",
           "risk" => "low",
           "why" => "response",
           "explanation" => text
         }}
    end
  end

  defp extract_json(text) do
    text = String.trim(text)

    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?\s*```/s, text) do
      [_, json] -> String.trim(json)
      nil -> text
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
    actor_key =
      if episode_ctx[:actor_id] do
        try do
          String.to_existing_atom(to_string(episode_ctx[:actor_id]))
        rescue
          _ -> nil
        end
      end

    from_persistent =
      if actor_key do
        :persistent_term.get({:cyclium_interactive_llm, actor_key}, nil)
      end

    from_persistent ||
      Application.get_env(:cyclium, :interactive_llm) ||
      raise "No LLM client configured for Cyclium.Synthesizer.Interactive. " <>
              "Set config :cyclium, :interactive_llm, MyApp.LLMClient"
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

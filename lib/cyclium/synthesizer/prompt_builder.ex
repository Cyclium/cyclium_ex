defmodule Cyclium.Synthesizer.PromptBuilder do
  @moduledoc """
  Builds system prompts for interactive actors from strategy_config.

  Generates the boilerplate JSON schema instructions, tool/action documentation,
  and response format guidance. The consuming app only needs to provide a short
  role description and domain-specific guidelines.

  ## Usage

  In `strategy_config`:

      strategy_config: %{
        role: "You are a Client Support Assistant for a SaaS health monitoring platform.",
        guidelines: [
          "If the user asks about a specific client by name, first use list_clients to find the ID",
          "Keep explanations concise and helpful"
        ],
        allowed_tool_signatures: [
          %{
            name: "client_support",
            side_effect: "write",
            actions: [
              %{name: "lookup_client", args: %{"client_id" => "UUID"}, description: "get full details for one client"},
              %{name: "list_clients", args: %{}, description: "list all clients with summary"},
              %{name: "initiate_health_check", args: %{"client_id" => "UUID"}, description: "trigger a full health review workflow", risk: "medium"}
            ]
          }
        ]
      }

  The Interactive synthesizer calls `build_system_prompt/1` when `strategy_config`
  has a `role` key instead of (or in addition to) a `system_prompt` key.
  """

  @doc """
  Build a complete system prompt from strategy_config.

  If the config has a `"system_prompt"` key, returns it as-is (backwards compatible).
  If it has a `"role"` key, generates the full prompt from role + tool signatures + guidelines.
  """
  def build(config) when is_map(config) do
    cond do
      config["system_prompt"] && config["system_prompt"] != "" ->
        config["system_prompt"]

      config["role"] ->
        build_from_config(config)

      true ->
        default_prompt()
    end
  end

  defp build_from_config(config) do
    role = config["role"]
    guidelines = config["guidelines"] || []
    signatures = config["allowed_tool_signatures"] || []

    sections =
      if native_tool_mode?(config) do
        # Native mode: tools are passed to the provider structurally and the model
        # replies with tool_use blocks, so we MUST NOT instruct a text JSON
        # envelope or list the tools as prose — doing so makes the model emit the
        # envelope as text instead of calling tools.
        [role, "", native_format_section(), "", guidelines_section(guidelines)]
      else
        [
          role,
          "",
          response_format_section(),
          "",
          tools_section(signatures),
          "",
          guidelines_section(guidelines),
          "",
          meta_section()
        ]
      end

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  # Native is the default; an actor opts out with `tool_mode: :text`. Must match
  # the synthesizer's path selection so the system prompt and the call style agree.
  defp native_tool_mode?(config), do: config["tool_mode"] not in [:text, "text"]

  defp native_format_section do
    """
    You have a set of tools available via the API. To act, call the appropriate
    tool directly with its arguments — do NOT describe a tool call in prose or
    emit JSON. When no tool is needed (or once tools have returned what you need),
    reply with a plain-text answer for the user.
    """
  end

  defp response_format_section do
    """
    You MUST respond with a valid JSON object (no markdown code fences).

    Response types:

    For tool calls:
    {"kind": "tool_call", "risk": "low", "why": "reason", "tool": {"tool": "TOOL_NAME", "action": "ACTION", "args": {ARGS}}}

    For explanations or answers:
    {"kind": "explain_only", "risk": "low", "why": "reason", "explanation": "your response text"}

    When a tool returns data, summarize the results clearly for the user.
    """
  end

  defp tools_section([]), do: ""

  defp tools_section(signatures) do
    tool_docs =
      Enum.map_join(signatures, "\n\n", fn sig ->
        name = sig["name"]
        actions = sig["actions"] || []

        if actions == [] do
          "Tool: #{name} (side_effect: #{sig["side_effect"] || "read"})"
        else
          action_lines =
            Enum.map_join(actions, "\n", fn action ->
              action_name = action["name"]
              args = action["args"] || %{}
              desc = action["description"] || ""
              risk = action["risk"]

              args_str =
                if args == %{} do
                  "{}"
                else
                  Jason.encode!(args)
                end

              risk_note = if risk, do: " [risk: #{risk}]", else: ""
              "  - #{action_name}: args #{args_str} — #{desc}#{risk_note}"
            end)

          "Tool: #{name}\n#{action_lines}"
        end
      end)

    "Available tools:\n\n#{tool_docs}"
  end

  defp guidelines_section([]), do: ""

  defp guidelines_section(guidelines) do
    lines = Enum.map_join(guidelines, "\n", &"- #{&1}")
    "Guidelines:\n#{lines}"
  end

  defp meta_section do
    ~s(To signal the conversation is done, include in your response:\n"meta": {"resolve_conversation": true, "outcome": "completed"})
  end

  defp default_prompt do
    """
    You are a helpful assistant. Respond with a valid JSON object matching the ActionPlan schema.

    For tool calls:
    {"kind": "tool_call", "risk": "low", "why": "reason", "tool": {"tool": "TOOL", "action": "ACTION", "args": {}}}

    For explanations:
    {"kind": "explain_only", "risk": "low", "why": "reason", "explanation": "your response"}
    """
  end
end

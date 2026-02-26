defmodule Cyclium.Terminology do
  @moduledoc """
  Provides configurable display labels for rendered logs and UI text.

  Consuming applications can override default terminology via application config:

      config :cyclium, :terminology, %{
        episode: "Cascade",
        finding: "Insight",
        raised: "created",
        completed: "resolved"
      }

  Unconfigured keys fall back to built-in defaults. Database values and schema
  atoms are never affected — this is purely for rendered display text.
  """

  @defaults %{
    # Concepts
    episode: "Episode",
    finding: "Finding",
    observation: "Observation",
    synthesis: "Synthesis",
    checkpoint: "Checkpoint",
    output: "Output",
    approval: "Approval",
    wait: "Wait",
    # Verbs / actions
    raised: "raised",
    updated: "updated",
    cleared: "cleared",
    completed: "completed",
    failed: "failed",
    resolved: "resolved",
    recorded: "recorded",
    requested: "requested",
    proposed: "proposed",
    delivered: "delivered",
    saved: "saved",
    started: "started"
  }

  @doc """
  Returns the display label for a terminology key.

  Falls back to the built-in default, then to stringifying the key.
  """
  def label(key) do
    overrides = Application.get_env(:cyclium, :terminology, %{})
    Map.get(overrides, key, Map.get(@defaults, key, humanize(key)))
  end

  @doc """
  Combines a concept label and an action label into a display string.

      iex> Cyclium.Terminology.format(:finding, :raised)
      "Finding raised"

  With config `%{finding: "Insight", raised: "created"}`:

      iex> Cyclium.Terminology.format(:finding, :raised)
      "Insight created"
  """
  def format(concept, action) do
    "#{label(concept)} #{label(action)}"
  end

  defp humanize(key) when is_atom(key), do: key |> Atom.to_string() |> String.replace("_", " ")
  defp humanize(key), do: to_string(key)
end

defmodule Cyclium.Strategy.TemplateRegistry do
  @moduledoc """
  Maps strategy template names (stored in `AgentDefinition.strategy_template`)
  to compiled strategy modules.

  ## Built-in templates

  | Template | Pattern | Use Case |
  |----------|---------|----------|
  | `"observe_synthesize_converge"` | Gather → LLM → Finding | Health checks, advisors |
  | `"observe_classify_converge"` | Gather → Rules → Finding | Threshold/rule actors |
  | `"dispatch"` | Load entities → Broadcast | Fan-out actors |
  """

  @templates %{
    "observe_synthesize_converge" => Cyclium.Strategy.Template.ObserveSynthesizeConverge,
    "observe_classify_converge" => Cyclium.Strategy.Template.ObserveClassifyConverge,
    "dispatch" => Cyclium.Strategy.Template.Dispatch
  }

  @doc """
  Resolves a template name to its strategy module.
  Returns `nil` if the template is not registered.
  """
  def resolve(template_name) when is_binary(template_name) do
    Map.get(all_templates(), template_name)
  end

  def resolve(_), do: nil

  @doc """
  Returns all registered templates including any app-defined extras.
  """
  def all_templates do
    custom = Application.get_env(:cyclium, :strategy_templates, %{})
    Map.merge(@templates, custom)
  end
end

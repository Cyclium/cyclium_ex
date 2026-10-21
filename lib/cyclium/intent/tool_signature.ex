defmodule Cyclium.Intent.ToolSignature do
  @moduledoc """
  A tool the strategy allows the model to call, declared in strategy config by
  the consuming app under `allowed_tool_signatures`.

  The runtime matches each planned tool call against these on **two** keys:

    * the tool `name` must match a signature, and
    * the step's `action` must be one the signature lists in `actions`.

  A signature that lists no actions allows **none**. The prompt and the native
  tool schema are built from the same list, so an action the model cannot see
  is not callable either. A tool whose every `call/3` clause is safe to expose
  may opt out with `"actions" => "*"` (or `:any`); do that deliberately.

  `side_effect` classifies the whole tool. An action entry may carry its own
  `"side_effect"` to override it, so a tool that mixes reads and one write can
  gate only the write behind preview.

      %{
        "name" => "widgets",
        "side_effect" => "read",
        "constraints" => %{"max_rows" => 500},
        "actions" => [
          %{"name" => "lookup", "args" => %{"id" => "widget id"}, "description" => "..."},
          %{"name" => "adjust", "side_effect" => "write", "args" => %{...}, "description" => "..."}
        ]
      }
  """

  @enforce_keys [:name, :version, :side_effect]
  defstruct [
    :name,
    :version,
    :side_effect,
    :args_schema,
    constraints: %{},
    actions: [],
    action_side_effects: %{}
  ]

  @type side_effect :: :read | :write | :external_effect

  @type t :: %__MODULE__{
          name: binary(),
          version: pos_integer(),
          side_effect: side_effect(),
          args_schema: binary() | nil,
          constraints: map(),
          actions: [binary()] | :any,
          action_side_effects: %{binary() => side_effect()}
        }

  @doc """
  Build a signature from one `allowed_tool_signatures` entry. Accepts string or
  atom keys (the Actor DSL normalises to strings, DB-loaded JSON is strings, and
  in-process callers may pass atoms).
  """
  @spec from_config(map()) :: t()
  def from_config(sig) when is_map(sig) do
    raw_actions = get(sig, :actions)

    %__MODULE__{
      name: get(sig, :name),
      version: get(sig, :version) || 1,
      side_effect: parse_side_effect(get(sig, :side_effect)),
      args_schema: get(sig, :args_schema),
      constraints: get(sig, :constraints) || %{},
      actions: parse_actions(raw_actions),
      action_side_effects: parse_action_side_effects(raw_actions)
    }
  end

  @doc "Whether `action` is callable under this signature."
  @spec allows_action?(t(), binary() | atom() | nil) :: boolean()
  def allows_action?(%__MODULE__{actions: :any}, _action), do: true

  def allows_action?(%__MODULE__{actions: actions}, action)
      when is_list(actions) and is_binary(action),
      do: action in actions

  def allows_action?(%__MODULE__{actions: actions}, action)
      when is_list(actions) and is_atom(action) and not is_nil(action),
      do: Atom.to_string(action) in actions

  def allows_action?(_signature, _action), do: false

  @doc """
  The side-effect class that applies to `action`: the action's own override when
  declared, otherwise the tool's class.
  """
  @spec side_effect_for(t(), binary() | atom() | nil) :: side_effect()
  def side_effect_for(%__MODULE__{} = sig, action) do
    Map.get(sig.action_side_effects, action_key(action), sig.side_effect)
  end

  @doc "Normalise a declared side-effect value; anything unrecognised is `:read`."
  @spec parse_side_effect(term()) :: side_effect()
  def parse_side_effect("read"), do: :read
  def parse_side_effect("write"), do: :write
  def parse_side_effect("external_effect"), do: :external_effect
  def parse_side_effect(atom) when atom in [:read, :write, :external_effect], do: atom
  def parse_side_effect(_), do: :read

  # --- internal ---

  defp get(sig, key) when is_atom(key) do
    case Map.fetch(sig, key) do
      {:ok, v} -> v
      :error -> Map.get(sig, Atom.to_string(key))
    end
  end

  defp parse_actions(:any), do: :any
  defp parse_actions("*"), do: :any

  defp parse_actions(list) when is_list(list) do
    list |> Enum.map(&action_name/1) |> Enum.reject(&is_nil/1)
  end

  defp parse_actions(_), do: []

  defp parse_action_side_effects(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      %{} = action, acc ->
        case {action_name(action), get(action, :side_effect)} do
          {name, se} when is_binary(name) and not is_nil(se) ->
            Map.put(acc, name, parse_side_effect(se))

          _ ->
            acc
        end

      _other, acc ->
        acc
    end)
  end

  defp parse_action_side_effects(_), do: %{}

  defp action_name(%{} = action), do: action |> get(:name) |> action_key()
  defp action_name(name) when is_binary(name), do: name
  defp action_name(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp action_name(_), do: nil

  defp action_key(nil), do: nil
  defp action_key(name) when is_binary(name), do: name
  defp action_key(name) when is_atom(name), do: Atom.to_string(name)
  defp action_key(other), do: to_string(other)
end

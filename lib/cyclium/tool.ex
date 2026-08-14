defmodule Cyclium.Tool do
  @moduledoc """
  Behaviour for tool implementations.
  Tools are provided by the consuming app and wrapped by ToolExec.

  ## Minimal implementation

      defmodule MyApp.Tools.ERP do
        use Cyclium.Tool

        def call(:read_po, args, _ctx), do: {:ok, fetch_po(args["po_id"])}
      end

  `use Cyclium.Tool` provides sensible defaults for all optional callbacks.
  Override any of them as needed.
  """

  @callback call(action :: atom(), args :: map(), ctx :: map()) ::
              {:ok, result :: term()} | {:error, reason :: term()}

  @callback redact(args :: map()) :: map()

  @callback redact_result(result :: term()) :: term()

  @doc """
  Advisory declaration of whether the tool mutates state. **This does not drive
  the approval gate.** Whether a planned call is gated for human preview is
  decided by the strategy's `allowed_tool_signatures` (the `side_effect` class
  — `"write"` / `"external_effect"` — matched by `Cyclium.Intent.SignatureMatcher`),
  not by this callback, which the runtime never reads at gate time. Setting
  `side_effect?/0 => true` alone will NOT gate a write tool; declare the effect
  in the signature the strategy allows. Keep the two consistent — treat this as
  the human-readable intent and let a test cross-check it against the signature.
  """
  @callback side_effect?() :: boolean()

  @callback cache_ttl() :: non_neg_integer() | :no_cache

  @callback cache_scope(args :: map()) :: binary()

  @doc """
  Optional self-description of the tool — its `name`, `side_effect` class,
  `constraints`, and `actions` (each with `name`/`description`/`args`) — in the
  same shape as an `allowed_tool_signatures` entry. Lets actors introspect tools
  generically (e.g. to build native tool schemas, or to validate that a tool an
  actor allows actually exists) instead of re-declaring every signature by hand.

  Defaults to `nil` ("not declared") via `use Cyclium.Tool`, so it is opt-in per
  tool: introspection stays generic (`MyTool.tool_signature()` is always
  callable) without forcing every existing tool to declare one.
  """
  @callback tool_signature() :: map() | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour Cyclium.Tool

      @impl true
      def redact(args), do: args

      @impl true
      def redact_result(result), do: result

      @impl true
      def side_effect?, do: false

      @impl true
      def cache_ttl, do: :no_cache

      @impl true
      def cache_scope(_args), do: ""

      @impl true
      def tool_signature, do: nil

      defoverridable redact: 1,
                     redact_result: 1,
                     side_effect?: 0,
                     cache_ttl: 0,
                     cache_scope: 1,
                     tool_signature: 0
    end
  end
end

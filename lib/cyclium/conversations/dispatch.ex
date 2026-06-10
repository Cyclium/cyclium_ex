defmodule Cyclium.Conversations.Dispatch do
  @moduledoc """
  Creates and enqueues interactive episodes for conversation turns.

  This is the library-level helper that eliminates boilerplate in consuming apps.
  It resolves the actor's interactive expectation, budget, and log strategy from
  persistent_term (set by the Actor DSL at startup) — no actor-specific knowledge needed.

  ## Usage in consuming apps

      # Direct call:
      Cyclium.Conversations.Dispatch.send_message(conversation_id, "Hello", principal: user)

      # Or wrap in a thin app-level module if you need customization:
      defmodule MyApp.ConversationDispatch do
        def send_message(conversation_id, message, opts \\\\ []) do
          Cyclium.Conversations.Dispatch.send_message(conversation_id, message, opts)
        end
      end
  """

  require Logger

  alias Cyclium.{Conversations, Episodes}

  @doc """
  Send a user message in a conversation. Creates an interactive episode and enqueues it.

  Resolves the actor's interactive expectation automatically from the conversation's
  `actor_id` — no hardcoded expectation IDs needed.

  ## Options
    - `:principal` — map with user info (e.g. `%{"type" => "user", "id" => "user_123"}`)
    - `:budget` — override budget (default: resolved from actor's expectation)
    - `:log_strategy` — override log strategy (default: resolved from actor's expectation)
    - `:expectation_id` — explicitly select the interactive expectation to use.

  Resolution order: this `:expectation_id` opt, then the expectation pinned on
  the conversation (`conversation.expectation_id`), then auto-resolution. For an
  actor with multiple interactive expectations and no pin, auto-resolution
  errors with `{:ambiguous_interactive_expectation, ids}`.

  Returns `{:ok, episode}` or `{:error, reason}`.
  """
  def send_message(conversation_id, message, opts \\ []) do
    conversation = Conversations.get!(conversation_id)
    actor_id = conversation.actor_id

    # Priority: explicit opt > expectation pinned on the conversation > auto-resolve.
    resolution =
      case Keyword.get(opts, :expectation_id) || conversation.expectation_id do
        nil -> resolve_interactive_expectation(actor_id)
        chosen -> resolve_named_expectation(actor_id, chosen)
      end

    case resolution do
      {:ok, expectation_id, budget, log_strategy} ->
        create_and_enqueue(
          conversation_id,
          message,
          actor_id,
          expectation_id,
          Keyword.get(opts, :budget, budget),
          Keyword.get(opts, :log_strategy, log_strategy),
          Keyword.get(opts, :principal)
        )

      {:error, reason} ->
        Logger.error("No interactive expectation found for actor #{actor_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # --- Private ---

  defp create_and_enqueue(
         conversation_id,
         message,
         actor_id,
         expectation_id,
         budget,
         log_strategy,
         principal
       ) do
    trigger_ref = %{
      "conversation_id" => conversation_id,
      "message" => message,
      "principal" => principal
    }

    attrs = %{
      actor_id: actor_id,
      expectation_id: to_string(expectation_id),
      trigger_type: :interactive,
      trigger_ref: trigger_ref,
      conversation_id: conversation_id,
      dedupe_key:
        "interactive:#{actor_id}:#{conversation_id}:#{System.system_time(:millisecond)}",
      status: :running,
      budget: normalize_budget(budget),
      log_strategy: to_string(log_strategy || :full_debug),
      mode: "live",
      started_at: DateTime.utc_now()
    }

    case Episodes.create(attrs) do
      {:ok, episode} ->
        Cyclium.Mode.runner_for(actor_id).enqueue(episode.id)

        Cyclium.Bus.broadcast("expectation.triggered", %{
          actor_id: actor_id,
          expectation_id: to_string(expectation_id),
          episode_id: episode.id,
          conversation_id: conversation_id
        })

        {:ok, episode}

      {:error, changeset} ->
        Logger.error("Failed to create interactive episode: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  @doc """
  Resolve the interactive expectation for an actor from persistent_term.

  Scans persistent_term for expectations registered with the Interactive
  strategy template. Also resolves budget and log_strategy for that expectation.

  Selection is deterministic:
    - zero matches → `{:error, :no_interactive_expectation}`
    - exactly one  → `{:ok, expectation_id, budget, log_strategy}`
    - two or more  → `{:error, {:ambiguous_interactive_expectation, sorted_ids}}`

  When an actor declares more than one interactive expectation, the conversation
  record (which only carries `actor_id`) can't say which one a turn belongs to,
  so resolution refuses to guess — pass `:expectation_id` to `send_message/3`.
  """
  def resolve_interactive_expectation(actor_id) do
    actor_key = safe_to_atom(actor_id)

    matches =
      :persistent_term.get()
      |> Enum.flat_map(fn
        {{:cyclium_actor_strategy, ^actor_key, exp_id}, Cyclium.Strategy.Template.Interactive} ->
          [exp_id]

        _ ->
          []
      end)
      |> Enum.sort()

    case matches do
      [] ->
        {:error, :no_interactive_expectation}

      [exp_id] ->
        {:ok, exp_id, expectation_budget(actor_key, exp_id),
         expectation_log_strategy(actor_key, exp_id)}

      [_ | _] = ids ->
        Logger.error(
          "Actor #{actor_id} declares multiple interactive expectations " <>
            "(#{inspect(ids)}); dispatch cannot choose one automatically. " <>
            "Pass :expectation_id to send_message/3 to disambiguate."
        )

        {:error, {:ambiguous_interactive_expectation, ids}}
    end
  end

  # Resolve a caller-specified expectation, verifying it is registered as an
  # Interactive expectation for this actor.
  defp resolve_named_expectation(actor_id, expectation_id) do
    actor_key = safe_to_atom(actor_id)

    # If the id was never interned as an atom, no expectation by that name can
    # exist — report it as unknown rather than letting to_existing_atom raise.
    case existing_atom(expectation_id) do
      nil ->
        {:error, {:unknown_expectation, expectation_id}}

      exp_key ->
        case :persistent_term.get({:cyclium_actor_strategy, actor_key, exp_key}, nil) do
          Cyclium.Strategy.Template.Interactive ->
            {:ok, exp_key, expectation_budget(actor_key, exp_key),
             expectation_log_strategy(actor_key, exp_key)}

          nil ->
            {:error, {:unknown_expectation, expectation_id}}

          other ->
            {:error, {:not_interactive_expectation, expectation_id, other}}
        end
    end
  end

  defp existing_atom(val) when is_atom(val), do: val

  defp existing_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> nil
  end

  defp expectation_budget(actor_key, exp_id),
    do: :persistent_term.get({:cyclium_expectation_budget, actor_key, exp_id}, nil)

  defp expectation_log_strategy(actor_key, exp_id),
    do: :persistent_term.get({:cyclium_expectation_log_strategy, actor_key, exp_id}, nil)

  defp normalize_budget(nil),
    do: %{"max_turns" => 20, "max_tokens" => 10_000, "max_wall_ms" => 120_000}

  defp normalize_budget(budget) when is_map(budget) do
    Map.new(budget, fn {k, v} -> {to_string(k), v} end)
  end

  defp safe_to_atom(val) when is_atom(val), do: val
  defp safe_to_atom(val) when is_binary(val), do: String.to_existing_atom(val)
end

defmodule Cyclium.Conversations.LiveHelpers do
  @moduledoc """
  Reusable helpers for conversation LiveViews.

  Provides bus event handling, message loading from episodes, and conversation
  lifecycle management. Consuming apps `use` this module to get module attributes
  and import the helper functions.

  ## Usage

      defmodule MyAppWeb.ConversationLive.Show do
        use MyAppWeb, :live_view
        use Cyclium.Conversations.LiveHelpers, actor_id: "my_actor"

        # @__actor_id and @__dispatch are set for you.
        # All helper functions are imported.
      end

  ## Options

    - `:actor_id` — required, the actor identifier for filtering bus events
    - `:dispatch` — dispatch module (default: `Cyclium.Conversations.Dispatch`)
  """

  defmacro __using__(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    dispatch = Keyword.get(opts, :dispatch, Cyclium.Conversations.Dispatch)

    quote do
      @__actor_id unquote(actor_id)
      @__dispatch unquote(dispatch)

      import Cyclium.Conversations.LiveHelpers
    end
  end

  alias Cyclium.{Conversations, Episodes}

  @doc """
  Load or create a conversation based on params and live_action.
  Returns `{conversation, messages}`.
  """
  def load_or_create_conversation(params, live_action, actor_id, principal) do
    case {params, live_action} do
      {%{"id" => id}, _} ->
        conversation = Conversations.get!(id)
        messages = load_messages_from_episodes(conversation.id)
        {conversation, messages}

      {_, :new} ->
        start_new_conversation(actor_id, principal)

      _ ->
        start_new_conversation(actor_id, principal)
    end
  end

  defp start_new_conversation(actor_id, principal) do
    {:ok, conversation} =
      Conversations.start(%{
        actor_id: actor_id,
        name: "Chat #{Calendar.strftime(DateTime.utc_now(), "%H:%M")}",
        principal: principal
      })

    {conversation, []}
  end

  @doc """
  Reconstruct chat messages from completed episodes in a conversation.
  """
  def load_messages_from_episodes(conversation_id) do
    Episodes.list_for_conversation(conversation_id, limit: 50)
    |> Enum.flat_map(fn ep ->
      user_msg =
        case ep.trigger_ref do
          %{"message" => msg} when is_binary(msg) ->
            [%{role: :user, content: msg, timestamp: ep.started_at}]

          _ ->
            []
        end

      assistant_msg =
        if ep.summary do
          [%{role: :assistant, content: ep.summary, timestamp: ep.finished_at || ep.started_at}]
        else
          []
        end

      user_msg ++ assistant_msg
    end)
  end

  @doc """
  Handle an `episode.completed` bus event for a conversation LiveView.

  Checks that the episode belongs to the current conversation. If it does,
  returns `{:ok, assigns_map}` with the updated assigns. Otherwise returns `:ignore`.

  ## Example

      def handle_info({:bus, "episode.completed", %{episode_id: eid, actor_id: @__actor_id}}, socket) do
        case on_episode_completed(eid, socket.assigns.conversation.id, socket.assigns.messages) do
          {:ok, new_assigns} -> {:noreply, assign(socket, new_assigns)}
          :ignore -> {:noreply, socket}
        end
      end
  """
  def on_episode_completed(episode_id, conversation_id, current_messages) do
    case Episodes.get(episode_id) do
      %{conversation_id: ^conversation_id} = episode ->
        summary = episode.summary || "Done."

        assistant_msg = %{
          role: :assistant,
          content: summary,
          timestamp: episode.finished_at || DateTime.utc_now()
        }

        conversation = Conversations.get!(conversation_id)

        {:ok,
         %{
           messages: current_messages ++ [assistant_msg],
           sending: false,
           conversation: conversation
         }}

      _ ->
        :ignore
    end
  end

  @doc """
  Handle an `episode.failed` bus event for a conversation LiveView.

  Returns `{:ok, assigns_map}` or `:ignore`.
  """
  def on_episode_failed(episode_id, conversation_id, current_messages) do
    case Episodes.get(episode_id) do
      %{conversation_id: ^conversation_id} ->
        error_msg = %{
          role: :assistant,
          content: "Sorry, something went wrong processing your request.",
          timestamp: DateTime.utc_now()
        }

        {:ok,
         %{
           messages: current_messages ++ [error_msg],
           sending: false
         }}

      _ ->
        :ignore
    end
  end

  @doc """
  Handle a conversation status change event. Returns updated conversation or `:ignore`.
  """
  def on_conversation_status_change(event_conv_id, current_conv_id) do
    if event_conv_id == current_conv_id do
      {:ok, Conversations.get!(event_conv_id)}
    else
      :ignore
    end
  end

  @doc """
  Dispatch a user message. Appends the user message to the message list and
  creates the episode.

  Returns `{:ok, updated_messages}` or `{:error, updated_messages, reason}`.
  """
  def dispatch_message(conversation_id, message, current_messages, dispatch_mod, opts \\ []) do
    user_msg = %{
      role: :user,
      content: message,
      timestamp: DateTime.utc_now()
    }

    messages = current_messages ++ [user_msg]

    case dispatch_mod.send_message(conversation_id, message, opts) do
      {:ok, _episode} ->
        {:ok, messages}

      {:error, reason} ->
        error_msg = %{
          role: :assistant,
          content: "Failed to send message. Please try again.",
          timestamp: DateTime.utc_now()
        }

        {:error, messages ++ [error_msg], reason}
    end
  end
end

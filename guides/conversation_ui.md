# Conversation UI Guide

This guide covers building a Phoenix LiveView chat interface for interactive actors. It assumes you've already set up the actor, LLM client, tools, and dispatch from the [Interactive Actors guide](interactive_actors.md).

## Overview

The conversation UI consists of:

| Component | Purpose |
|---|---|
| **`Cyclium.Conversations.LiveHelpers`** | Library-level helpers for bus handling, message loading, and dispatch |
| **ConversationComponents** | Shared function components (header, message list, message bubble, input bar) |
| **ConversationLive.Show** | Chat page — creates/loads conversation, sends messages, displays responses |
| **ConversationLive.Index** | List page — shows all conversations for the actor |
| **JS Hooks** | ScrollToBottom (auto-scroll on new messages), FocusInput (refocus after send) |
| **CSS** | Chat container layout, message bubbles, input bar |
| **Routes** | `/conversations`, `/conversations/new`, `/conversations/:id` |

## 1. Library Helpers

`Cyclium.Conversations.LiveHelpers` provides reusable functions that eliminate most of the boilerplate in conversation LiveViews. Use it with the `use` macro:

```elixir
use Cyclium.Conversations.LiveHelpers, actor_id: "support_actor"
```

This sets two module attributes and imports all helper functions:
- `@__actor_id` — your actor's identifier (for bus event filtering)
- `@__dispatch` — dispatch module (default: `Cyclium.Conversations.Dispatch`)

### Available functions

| Function | Returns | Purpose |
|---|---|---|
| `load_or_create_conversation/4` | `{conversation, messages}` | Mount helper — loads existing or creates new |
| `load_messages_from_episodes/1` | `[%{role, content, timestamp}]` | Reconstructs chat history from episodes |
| `on_episode_completed/3` | `{:ok, assigns_map}` or `:ignore` | Handles episode.completed bus event |
| `on_episode_failed/3` | `{:ok, assigns_map}` or `:ignore` | Handles episode.failed bus event |
| `on_conversation_status_change/2` | `{:ok, conversation}` or `:ignore` | Handles conversation lifecycle events |
| `dispatch_message/5` | `{:ok, messages}` or `{:error, messages, reason}` | Sends a message and returns updated message list |

The helpers return plain data — they don't call `assign` or `put_flash` directly. This keeps the library free of Phoenix compile-time dependencies and gives you full control over socket updates.

## 2. Shared Components

Create a function component module for reusable chat UI elements:

```elixir
defmodule MyAppWeb.ConversationComponents do
  use Phoenix.Component

  attr :conversation, :map, required: true

  def conversation_header(assigns) do
    status_class =
      case assigns.conversation.status do
        "open" -> "badge badge-green"
        "resolved" -> "badge"
        "abandoned" -> "badge badge-red"
        "timed_out" -> "badge badge-yellow"
        _ -> "badge"
      end

    assigns = assign(assigns, :status_class, status_class)

    ~H"""
    <div class="chat-header">
      <div style="display: flex; align-items: center; gap: 0.75rem;">
        <h2 style="margin: 0; font-size: 1rem; font-weight: 600;">{@conversation.name}</h2>
        <span class={@status_class}>{@conversation.status}</span>
      </div>
      <div class="text-muted text-sm">
        Turns: {@conversation.turns_used || 0}
      </div>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :sending, :boolean, default: false

  def message_list(assigns) do
    ~H"""
    <div id="message-list" class="chat-messages" phx-hook="ScrollToBottom">
      <div :if={@messages == []} class="empty-state" style="padding: 3rem;">
        <p class="text-muted">Start a conversation by typing a message below.</p>
      </div>
      <.message_bubble :for={msg <- @messages} message={msg} />
      <div :if={@sending} class="message-bubble message-assistant">
        <div class="message-content">
          <span class="badge badge-evaluating">thinking...</span>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true

  def message_bubble(assigns) do
    bubble_class =
      case assigns.message.role do
        :user -> "message-bubble message-user"
        :assistant -> "message-bubble message-assistant"
        _ -> "message-bubble message-assistant"
      end

    assigns = assign(assigns, :bubble_class, bubble_class)

    ~H"""
    <div class={@bubble_class}>
      <div class="message-role">{role_label(@message.role)}</div>
      <div class="message-content">{@message.content}</div>
      <div :if={@message[:timestamp]} class="message-time">
        {format_time(@message.timestamp)}
      </div>
    </div>
    """
  end

  attr :sending, :boolean, default: false
  attr :conversation_open, :boolean, default: true

  def input_bar(assigns) do
    ~H"""
    <div class="chat-input-bar">
      <form phx-submit="send_message" style="display: flex; gap: 0.5rem; width: 100%;">
        <input
          type="text"
          name="message"
          placeholder={
            if @conversation_open, do: "Type a message...", else: "Conversation ended"
          }
          autocomplete="off"
          disabled={@sending or not @conversation_open}
          class="chat-input"
          id="chat-input"
          phx-hook="FocusInput"
        />
        <button
          type="submit"
          class="btn btn-primary"
          disabled={@sending or not @conversation_open}
        >
          {if @sending, do: "Sending...", else: "Send"}
        </button>
      </form>
    </div>
    """
  end

  defp role_label(:user), do: "You"
  defp role_label(:assistant), do: "Assistant"
  defp role_label(_), do: "System"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""
end
```

**Key design decisions:**
- `message_list` uses `phx-hook="ScrollToBottom"` to auto-scroll when new messages arrive
- The "thinking..." indicator shows when `@sending` is true (between message dispatch and episode completion)
- `input_bar` disables when sending or when the conversation is no longer open (resolved/abandoned/timed_out)
- `FocusInput` hook refocuses the text input after each form submit

## 3. Chat Page (ConversationLive.Show)

The chat page uses `LiveHelpers` to handle the heavy lifting. Compare with the "without helpers" version in the collapsed section below — the helpers cut the LiveView roughly in half.

```elixir
defmodule MyAppWeb.ConversationLive.Show do
  use MyAppWeb, :live_view
  use Cyclium.Conversations.LiveHelpers, actor_id: "support_actor"

  import MyAppWeb.ConversationComponents

  @principal %{"type" => "user", "id" => "demo_user", "label" => "Demo User"}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Cyclium.Bus.subscribe()

    {conversation, messages} =
      load_or_create_conversation(params, socket.assigns.live_action, @__actor_id, @principal)

    {:ok,
     socket
     |> assign(:conversation, conversation)
     |> assign(:messages, messages)
     |> assign(:sending, false)
     |> assign(:page_title, "Chat: #{conversation.name}")}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # --- Events ---

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      case dispatch_message(
             socket.assigns.conversation.id,
             message,
             socket.assigns.messages,
             @__dispatch,
             principal: @principal
           ) do
        {:ok, messages} ->
          {:noreply, assign(socket, messages: messages, sending: true)}

        {:error, messages, _reason} ->
          {:noreply,
           socket
           |> assign(:messages, messages)
           |> put_flash(:error, "Failed to dispatch episode")}
      end
    end
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/conversations/new")}
  end

  # --- Bus events ---

  @impl true
  def handle_info({:bus, "episode.completed", %{episode_id: eid, actor_id: @__actor_id}}, socket) do
    case on_episode_completed(eid, socket.assigns.conversation.id, socket.assigns.messages) do
      {:ok, new_assigns} -> {:noreply, assign(socket, new_assigns)}
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info({:bus, "episode.failed", %{episode_id: eid, actor_id: @__actor_id}}, socket) do
    case on_episode_failed(eid, socket.assigns.conversation.id, socket.assigns.messages) do
      {:ok, new_assigns} -> {:noreply, assign(socket, new_assigns)}
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info({:bus, event, %{conversation_id: conv_id}}, socket)
      when event in [
             "conversation.resolved",
             "conversation.timed_out",
             "conversation.abandoned"
           ] do
    case on_conversation_status_change(conv_id, socket.assigns.conversation.id) do
      {:ok, conversation} -> {:noreply, assign(socket, :conversation, conversation)}
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info({:bus, _event, _payload}, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    conversation_open = assigns.conversation.status == "open"
    assigns = assign(assigns, :conversation_open, conversation_open)

    ~H"""
    <div class="chat-container">
      <div class="chat-top-bar">
        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <.link navigate={~p"/conversations"} class="text-muted">&larr; Back</.link>
          <.conversation_header conversation={@conversation} />
        </div>
        <div style="display: flex; gap: 0.5rem;">
          <button phx-click="new_conversation" class="btn btn-secondary btn-sm">
            New Chat
          </button>
        </div>
      </div>

      <.message_list messages={@messages} sending={@sending} />
      <.input_bar sending={@sending} conversation_open={@conversation_open} />
    </div>
    """
  end
end
```

### Key patterns

**Bus event handling — the double filter:**
1. `actor_id: @__actor_id` in the pattern match — ignores events from workflow step episodes
2. `on_episode_completed/3` checks `conversation_id` — ignores events from other conversations

Both filters are required. Without actor_id filtering, tools that trigger workflows (like `initiate_health_check`) will cause the chat to show spurious error/completion messages from the workflow's internal episodes.

**Data-returning helpers:**
The `on_*` helpers return `{:ok, assigns_map}` or `:ignore` — you apply them to the socket with `assign/2`. This keeps Phoenix-specific code in the LiveView where it belongs.

## 4. Conversation List Page (ConversationLive.Index)

A simple list of all conversations for the actor, with real-time updates.

```elixir
defmodule MyAppWeb.ConversationLive.Index do
  use MyAppWeb, :live_view

  alias Cyclium.Conversations

  @actor_id "support_actor"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Cyclium.Bus.subscribe()

    conversations = Conversations.list_for_actor(@actor_id)

    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:conversations, conversations)}
  end

  @impl true
  def handle_info({:bus, event, _payload}, socket)
      when event in [
             "conversation.resolved",
             "conversation.abandoned",
             "conversation.timed_out",
             "episode.completed",
             "episode.failed"
           ] do
    conversations = Conversations.list_for_actor(@actor_id)
    {:noreply, assign(socket, :conversations, conversations)}
  end

  def handle_info({:bus, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-header">
      <h1>Conversations</h1>
      <.link navigate={~p"/conversations/new"} class="btn btn-primary">New Conversation</.link>
    </div>

    <table :if={@conversations != []}>
      <thead>
        <tr>
          <th>Name</th>
          <th>Status</th>
          <th>Turns</th>
          <th>Last Updated</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={conv <- @conversations}>
          <td>
            <.link navigate={~p"/conversations/#{conv.id}"}>{conv.name}</.link>
          </td>
          <td>
            <span class={status_badge(conv.status)}>{conv.status}</span>
          </td>
          <td>{conv.turns_used || 0}</td>
          <td class="text-muted text-sm">
            {Calendar.strftime(conv.updated_at, "%Y-%m-%d %H:%M:%S")}
          </td>
          <td>
            <.link navigate={~p"/conversations/#{conv.id}"} class="btn btn-secondary btn-sm">
              Open
            </.link>
          </td>
        </tr>
      </tbody>
    </table>

    <div :if={@conversations == []} class="empty-state">
      <p class="text-muted">No conversations yet.</p>
    </div>
    """
  end

  defp status_badge("open"), do: "badge badge-green"
  defp status_badge("resolved"), do: "badge"
  defp status_badge("abandoned"), do: "badge badge-red"
  defp status_badge("timed_out"), do: "badge badge-yellow"
  defp status_badge(_), do: "badge"
end
```

**Notes:**
- `Conversations.list_for_actor/2` is a library function — queries by `actor_id`, ordered by `updated_at DESC`
- The list refreshes on any relevant bus event (episode completed/failed, conversation status changes)
- Each row links to the chat page at `/conversations/:id`

## 5. Routes

Add inside your existing `scope "/"` block:

```elixir
# lib/my_app_web/router.ex
scope "/", MyAppWeb do
  pipe_through :browser

  # ... existing routes ...

  live "/conversations", ConversationLive.Index, :index
  live "/conversations/new", ConversationLive.Show, :new
  live "/conversations/:id", ConversationLive.Show, :show
end
```

The `:new` and `:show` actions are handled by the same LiveView (`ConversationLive.Show`) via `live_action` in `load_or_create_conversation/4`.

## 6. JS Hooks

Add these hooks to your LiveSocket initialization (typically in `root.html.heex` or `app.js`):

```javascript
let Hooks = {};

// Auto-scroll message list to bottom when new messages arrive
Hooks.ScrollToBottom = {
  mounted() { this.el.scrollTop = this.el.scrollHeight; },
  updated() { this.el.scrollTop = this.el.scrollHeight; }
};

// Refocus the input field after form submit (LiveView clears focus)
Hooks.FocusInput = {
  mounted() {
    this.el.focus();
    this.el.form && this.el.form.addEventListener("submit", () => {
      setTimeout(() => { this.el.value = ""; this.el.focus(); }, 50);
    });
  },
  updated() { this.el.focus(); }
};

let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks
});
```

**Why these hooks matter:**
- Without `ScrollToBottom`, the user has to manually scroll down after each new message
- Without `FocusInput`, the user has to click back into the text field after every message send
- The `setTimeout` in `FocusInput` clears the input value and refocuses after LiveView processes the form submission

## 7. CSS

Add these styles to your layout or stylesheet. The chat UI uses a flex column layout that fills the available viewport height.

```css
/* Chat container — fills viewport below nav */
.chat-container {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 80px); /* adjust 80px to match your nav height */
  max-width: 800px;
  margin: 0 auto;
  padding-bottom: env(safe-area-inset-bottom, 0px);
}

/* Top bar with conversation header and actions */
.chat-top-bar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.75rem 0;
  border-bottom: 1px solid var(--border-color, #333);
  flex-shrink: 0;
}

/* Scrollable message area */
.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 1rem 0;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

/* Individual message bubble */
.message-bubble {
  max-width: 80%;
  padding: 0.75rem 1rem;
  border-radius: 12px;
  line-height: 1.5;
}

/* User messages — right-aligned, accent color */
.message-user {
  align-self: flex-end;
  background: var(--accent-bg, #1a3a5c);
  border-bottom-right-radius: 4px;
}

/* Assistant messages — left-aligned, surface color */
.message-assistant {
  align-self: flex-start;
  background: var(--surface-bg, #1e1e1e);
  border: 1px solid var(--border-color, #333);
  border-bottom-left-radius: 4px;
}

/* Role label above message content */
.message-role {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  opacity: 0.6;
  margin-bottom: 0.25rem;
}

/* Message content text */
.message-content {
  white-space: pre-wrap;
  word-break: break-word;
}

/* Timestamp below message */
.message-time {
  font-size: 0.7rem;
  opacity: 0.4;
  margin-top: 0.25rem;
  text-align: right;
}

/* Fixed input bar at bottom — extra padding for breathing room */
.chat-input-bar {
  padding: 1rem 0 1.5rem;
  border-top: 1px solid var(--border-color, #333);
  flex-shrink: 0;
  margin-bottom: 0.5rem;
}

/* Text input field */
.chat-input {
  flex: 1;
  padding: 0.75rem 1rem;
  border: 1px solid var(--border-color, #333);
  border-radius: 8px;
  background: var(--input-bg, #1a1a1a);
  color: inherit;
  font-size: 0.9rem;
  min-height: 2.75rem;
}

.chat-input:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

/* Thinking indicator */
.badge-evaluating {
  animation: pulse 1.5s ease-in-out infinite;
}

@keyframes pulse {
  0%, 100% { opacity: 0.4; }
  50% { opacity: 1; }
}
```

**Layout notes:**
- `height: calc(100vh - 80px)` — adjust `80px` to your actual nav bar height
- The flex column layout ensures the message area grows to fill space while the input bar stays at the bottom
- `padding-bottom: env(safe-area-inset-bottom)` handles mobile safe areas
- Input bar has extra bottom padding and margin for breathing room
- CSS variables (`--border-color`, `--surface-bg`, etc.) allow easy theming

## 8. Nav Link

Add a link to your nav bar:

```html
<a href="/conversations" class="nav-link">Chat</a>
```

## Complete File List

| File | What it does |
|---|---|
| `lib/my_app_web/components/conversation_components.ex` | Shared function components |
| `lib/my_app_web/live/conversation_live/show.ex` | Chat page LiveView |
| `lib/my_app_web/live/conversation_live/index.ex` | List page LiveView |
| `lib/my_app_web/router.ex` | Routes (3 new lines) |
| `lib/my_app_web/components/layouts/root.html.heex` | Nav link + JS hooks + CSS |

## Common Issues

### "Sorry, something went wrong" from unrelated actors

If your interactive actor's tools trigger workflows (e.g., `initiate_health_check` → `ClientHealthWorkflow`), the workflow's internal episodes broadcast `episode.completed`/`episode.failed` on the Bus. The chat LiveView receives these too.

**Fix:** Pattern match on `actor_id: @__actor_id` in both `episode.completed` and `episode.failed` handlers. See section 3 above.

### Messages don't auto-scroll

Ensure the `ScrollToBottom` hook is registered in your LiveSocket and the message list div has `phx-hook="ScrollToBottom"`. The hook fires on both `mounted()` and `updated()`.

### Input loses focus after sending

The `FocusInput` hook handles this. It clears the input value and refocuses after form submission. Without the `setTimeout`, the focus happens before LiveView processes the event and gets cleared.

### "thinking..." indicator stays forever

This means the episode never completed or failed, or the bus event wasn't received. Check:
1. Is `Cyclium.Bus.subscribe()` called in `mount` (inside `connected?` guard)?
2. Is the actor_id filter correct in the `handle_info` pattern?
3. Did the episode actually complete? Check `/episodes` page or DB.

### Message history lost on page reload

Messages are reconstructed from episodes on mount via `load_messages_from_episodes/1` (from `LiveHelpers`). This queries `Episodes.list_for_conversation/2` and extracts user messages from `trigger_ref["message"]` and assistant responses from `episode.summary`. If episodes exist but messages don't show, check that `trigger_ref` is being stored correctly by `Cyclium.Conversations.Dispatch`.

### Conversation shows as "open" after user says goodbye

The LLM can signal conversation resolution by including `"meta": {"resolve_conversation": true}` in its ActionPlan response. The `ConversationHook` (called post-converge) checks for this and calls `Conversations.resolve/2`. The LiveView handles the `"conversation.resolved"` bus event to update the UI status. If it's not working, check that the system prompt tells the LLM about the `meta.resolve_conversation` field.

defmodule ClaudeNotify.TelegramPoller do
  @moduledoc """
  GenServer that long-polls Telegram getUpdates for:
  - Inline keyboard callbacks (Yes/No button presses)
  - Text messages (/sessions command, prompt text to inject)

  Maintains a "selected session" per chat so users can pick a session
  and then type prompts that get injected into that terminal.
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{Telegram, SessionStore, TerminalInjector, MessageFormatter, Dashboard}

  @poll_timeout 30
  @retry_delay 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("TelegramPoller: starting with long polling")
    send(self(), :poll)
    {:ok, %{offset: 0, selected_sessions: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    case Telegram.get_updates(state.offset, @poll_timeout) do
      {:ok, []} ->
        send(self(), :poll)
        {:noreply, state}

      {:ok, updates} ->
        {new_offset, new_state} = process_updates(updates, state)
        send(self(), :poll)
        {:noreply, %{new_state | offset: new_offset}}

      {:error, reason} ->
        Logger.warning(
          "TelegramPoller: poll failed: #{inspect(reason)}, retrying in #{@retry_delay}ms"
        )

        Process.send_after(self(), :poll, @retry_delay)
        {:noreply, state}
    end
  end

  defp process_updates(updates, state) do
    Enum.reduce(updates, {state.offset, state}, fn update, {max_offset, acc_state} ->
      update_id = update["update_id"]
      new_state = handle_update(update, acc_state)
      {max(max_offset, update_id + 1), new_state}
    end)
  end

  defp handle_update(%{"callback_query" => callback_query}, state)
       when not is_nil(callback_query) do
    handle_callback(callback_query, state)
  end

  defp handle_update(%{"message" => message}, state) when not is_nil(message) do
    handle_message(message, state)
  end

  defp handle_update(_update, state), do: state

  # --- Callback query handling (button presses) ---

  defp handle_callback(callback_query, state) do
    callback_id = callback_query["id"]
    data = callback_query["data"]
    chat_id = get_in(callback_query, ["message", "chat", "id"])

    if not authorized_chat?(chat_id) do
      Logger.warning(
        "TelegramPoller: unauthorized callback query",
        event: "unauthorized_telegram_callback",
        chat_id: inspect(chat_id)
      )

      Telegram.answer_callback_query(callback_id, "Unauthorized")
      state
    else
      Logger.info("TelegramPoller: callback: #{data}")

      case parse_callback_data(data) do
        {:select, session_id} ->
          Telegram.answer_callback_query(callback_id, "Session selected")
          handle_session_select(chat_id, session_id, state)

        {:dash_refresh} ->
          Telegram.answer_callback_query(callback_id, "Refreshing...")
          Dashboard.refresh()
          state

        {:response, session_id, response} ->
          Telegram.answer_callback_query(callback_id, response_label(response))
          inject_response(session_id, response)
          state

        :error ->
          Telegram.answer_callback_query(callback_id, "Invalid action")
          state
      end
    end
  end

  # --- Text message handling ---

  defp handle_message(message, state) do
    chat_id = get_in(message, ["chat", "id"])

    if not authorized_chat?(chat_id) do
      Logger.warning(
        "TelegramPoller: unauthorized message",
        event: "unauthorized_telegram_message",
        chat_id: inspect(chat_id)
      )

      state
    else
      # Guard: only handle text messages
      case message["text"] do
        nil ->
          Telegram.send_message(
            MessageFormatter.escape_full(
              "Only text messages are supported. Use /help for commands."
            )
          )

          state

        text ->
          handle_text_command(chat_id, text, state)
      end
    end
  end

  defp handle_text_command(chat_id, text, state) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        state

      String.starts_with?(trimmed, "/dashboard") ->
        Dashboard.create(chat_id)
        state

      String.starts_with?(trimmed, "/sessions") or String.starts_with?(trimmed, "/select") ->
        send_session_list(chat_id)
        state

      String.starts_with?(trimmed, "/switch") or trimmed == "/s" ->
        send_session_list(chat_id)
        state

      String.starts_with?(trimmed, "/cancel") ->
        handle_shortcut_command(chat_id, "escape", state)

      String.starts_with?(trimmed, "/approve") ->
        handle_shortcut_command(chat_id, "yes", state)

      String.starts_with?(trimmed, "/help") ->
        send_help(chat_id)
        state

      String.starts_with?(trimmed, "/") ->
        Telegram.send_message(
          MessageFormatter.escape_full("Unknown command. Use /help for available commands.")
        )

        state

      true ->
        handle_text_input(chat_id, trimmed, state)
    end
  end

  # --- Shortcut commands (cancel/approve) ---

  defp handle_shortcut_command(chat_id, response, state) do
    case resolve_session(chat_id, state) do
      {:ok, session_id, state} ->
        inject_response(session_id, response)

        label = response_label(response)

        Telegram.send_message(
          MessageFormatter.escape_full("#{label} (#{String.slice(session_id, 0, 8)})")
        )

        state

      {:error, :no_session, state} ->
        state
    end
  end

  # Auto-selects session when only one is active, otherwise prompts
  defp resolve_session(chat_id, state) do
    case Map.get(state.selected_sessions, chat_id) do
      nil ->
        sessions =
          SessionStore.all_sessions()
          |> Enum.reject(fn {id, _} -> id == "unknown" end)

        case sessions do
          [{id, _}] ->
            # Auto-select the only active session
            new_selected = Map.put(state.selected_sessions, chat_id, id)
            {:ok, id, %{state | selected_sessions: new_selected}}

          [] ->
            Telegram.send_message(MessageFormatter.escape_full("No active sessions."))

            {:error, :no_session, state}

          _ ->
            Telegram.send_message(
              MessageFormatter.escape_full(
                "Multiple sessions active. Use /sessions to select one first."
              )
            )

            {:error, :no_session, state}
        end

      session_id ->
        case SessionStore.get_session(session_id) do
          nil ->
            Telegram.send_message(
              MessageFormatter.escape_full("Session expired. Use /sessions to pick a new one.")
            )

            new_selected = Map.delete(state.selected_sessions, chat_id)
            {:error, :no_session, %{state | selected_sessions: new_selected}}

          _session ->
            {:ok, session_id, state}
        end
    end
  end

  # --- Session selection ---

  defp handle_session_select(chat_id, session_id, state) do
    case SessionStore.get_session(session_id) do
      nil ->
        Telegram.send_message(MessageFormatter.escape_full("Session not found\\."))
        state

      session ->
        project = Path.basename(session[:working_dir] || "unknown")
        short_id = String.slice(session_id, 0, 8)

        text =
          [
            "*Session selected*",
            "",
            "Project: `#{MessageFormatter.escape_code_public(project)}`",
            "ID: `#{MessageFormatter.escape_code_public(short_id)}`",
            "",
            MessageFormatter.escape_full("Type a message and I'll send it to this session.")
          ]
          |> Enum.join("\n")

        Telegram.send_message(text)
        new_selected = Map.put(state.selected_sessions, chat_id, session_id)
        %{state | selected_sessions: new_selected}
    end
  end

  # --- Text injection ---

  defp handle_text_input(chat_id, text, state) do
    case resolve_session(chat_id, state) do
      {:ok, session_id, state} ->
        session = SessionStore.get_session(session_id)
        tty_path = session[:tty_path]
        short_id = String.slice(session_id, 0, 8)
        truncated = String.slice(text, 0, 100)

        case TerminalInjector.send_text(tty_path, text) do
          :ok ->
            Telegram.send_message(
              MessageFormatter.escape_full("Sent to #{short_id}: #{truncated}")
            )

          {:error, reason} ->
            Logger.warning("TelegramPoller: send_text failed: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full(
                "Failed to send to #{short_id} (tty: #{tty_path || "none"}): #{inspect(reason)}"
              )
            )
        end

        state

      {:error, :no_session, state} ->
        state
    end
  end

  # --- Session list ---

  defp send_session_list(chat_id) do
    sessions =
      SessionStore.all_sessions()
      |> Enum.reject(fn {id, _session} -> id == "unknown" end)
      |> Map.new()

    if map_size(sessions) == 0 do
      Telegram.send_message(MessageFormatter.escape_full("No active sessions."))
    else
      buttons =
        Enum.map(sessions, fn {id, session} ->
          project = Path.basename(session[:working_dir] || "unknown")
          short_id = String.slice(id, 0, 8)
          label = "#{project} (#{short_id})"
          [label, "select:#{id}"]
        end)

      # One button per row for readability
      inline_keyboard =
        Enum.map(buttons, fn [label, data] ->
          [%{text: label, callback_data: data}]
        end)

      body = %{
        chat_id: chat_id,
        text:
          "*Active Sessions*\n\n#{MessageFormatter.escape_full("Select a session to send prompts to:")}",
        parse_mode: "MarkdownV2",
        reply_markup: %{inline_keyboard: inline_keyboard}
      }

      Telegram.api_post_public("sendMessage", body)
    end
  end

  defp send_help(chat_id) do
    text =
      [
        "*Commands*",
        "",
        MessageFormatter.escape_full("/dashboard - Show live session dashboard"),
        MessageFormatter.escape_full("/sessions - List and select active sessions"),
        MessageFormatter.escape_full("/switch or /s - Quick session switch"),
        MessageFormatter.escape_full("/approve - Send Yes to selected session"),
        MessageFormatter.escape_full("/cancel - Send Escape to selected session"),
        MessageFormatter.escape_full("/help - Show this help"),
        "",
        MessageFormatter.escape_full(
          "After selecting a session, type any text to send it as a prompt."
        ),
        MessageFormatter.escape_full("If only one session is active, it's auto-selected."),
        MessageFormatter.escape_full("Button responses (Yes/No) work on notification messages.")
      ]
      |> Enum.join("\n")

    body = %{chat_id: chat_id, text: text, parse_mode: "MarkdownV2"}
    Telegram.api_post_public("sendMessage", body)
  end

  # --- Helpers ---

  defp parse_callback_data("dash:refresh"), do: {:dash_refresh}

  defp parse_callback_data(data) when is_binary(data) do
    case String.split(data, ":", parts: 2) do
      ["select", session_id] when session_id != "" ->
        {:select, session_id}

      [session_id, response] when session_id != "" and response != "" ->
        {:response, session_id, response}

      _ ->
        :error
    end
  end

  defp parse_callback_data(_), do: :error

  defp inject_response(session_id, response) do
    case SessionStore.get_session(session_id) do
      nil ->
        Logger.warning("TelegramPoller: session #{session_id} not found")

      session ->
        tty_path = session[:tty_path]

        case TerminalInjector.send_response(tty_path, response) do
          :ok ->
            :ok

          {:error, reason} ->
            short_id = String.slice(session_id, 0, 8)

            Logger.warning("TelegramPoller: inject failed for #{short_id}: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full(
                "Failed to inject #{response_label(response)} into #{short_id}"
              )
            )
        end
    end
  end

  defp response_label("yes"), do: "Sent: Yes"
  defp response_label("yes_dont_ask"), do: "Sent: Yes (don't ask)"
  defp response_label("no"), do: "Sent: No"
  defp response_label("escape"), do: "Sent: Escape"
  defp response_label("opt_" <> n), do: "Sent: Option #{n}"
  defp response_label(_), do: "Sent"

  @doc false
  def authorized_chat?(chat_id) do
    configured = Application.get_env(:claude_notify, :telegram_chat_id)
    to_string(chat_id) == to_string(configured)
  end
end

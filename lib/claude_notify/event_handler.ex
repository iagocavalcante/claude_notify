defmodule ClaudeNotify.EventHandler do
  require Logger

  alias ClaudeNotify.{SessionStore, MessageFormatter, Telegram, TranscriptReader}

  @update_interval 10

  def handle_event(%{"event" => "prompt"} = params) do
    session_id = params["session_id"]
    prompt = params["prompt"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts = Map.take(params, ["tty_path", "term_session_id"])
    {action, session} = SessionStore.register_prompt(session_id, prompt, working_dir, opts)

    case action do
      :new_session ->
        message = MessageFormatter.session_started(session)
        Telegram.send_message(message)

      :prompt_update ->
        if rem(session.prompt_count, @update_interval) == 0 do
          message = MessageFormatter.session_update(session)
          Telegram.send_message(message)
        else
          :ok
        end
    end
  end

  def handle_event(%{"event" => "stop"} = params) do
    session_id = params["session_id"]
    stop_reason = params["stop_reason"] || "unknown"
    working_dir = params["working_dir"] || "unknown"

    # Try to send the last assistant response before the stop message
    send_last_response(session_id, params["transcript_path"])

    case SessionStore.get_session(session_id) do
      nil ->
        now = System.system_time(:second)

        session = %{
          id: session_id,
          working_dir: working_dir,
          prompt_count: 0,
          started_at: now,
          stopped_at: now,
          stop_reason: stop_reason
        }

        message = MessageFormatter.session_stopped(session)
        Telegram.send_message(message)

      _session ->
        {_action, session} = SessionStore.register_stop(session_id, stop_reason)
        message = MessageFormatter.session_stopped(session)
        Telegram.send_message(message)
    end
  end

  def handle_event(%{"event" => "tool_use"} = params) do
    session_id = params["session_id"]
    tool_name = params["tool_name"] || "unknown"
    tool_input = params["tool_input"] || ""
    tool_output = params["tool_output"] || ""
    working_dir = params["working_dir"] || "unknown"

    # Update session with TTY, transcript path, and working_dir
    opts = Map.take(params, ["tty_path", "term_session_id", "transcript_path"])
    update_session_tty(session_id, working_dir, opts)

    message = MessageFormatter.tool_use(tool_name, tool_input, tool_output)
    Telegram.send_message(message)
  end

  def handle_event(%{"event" => "notification"} = params) do
    session_id = params["session_id"]
    message = params["message"] || ""
    working_dir = params["working_dir"] || "unknown"

    # Update session with TTY, transcript path, and working_dir
    opts = Map.take(params, ["tty_path", "term_session_id", "transcript_path"])
    update_session_tty(session_id, working_dir, opts)

    # Send the last assistant response (Claude's summary before asking)
    send_last_response(session_id, params["transcript_path"])

    text = MessageFormatter.notification_question(message, session_id)
    buttons = notification_buttons(session_id)
    Telegram.send_with_buttons(text, buttons)
  end

  def handle_event(params) do
    Logger.warning("Unknown event: #{inspect(params)}")
    {:error, :unknown_event}
  end

  defp notification_buttons(session_id) do
    [
      ["Yes", "#{session_id}:yes"],
      ["Yes (don't ask)", "#{session_id}:yes_dont_ask"],
      ["No", "#{session_id}:no"],
      ["Esc", "#{session_id}:escape"]
    ]
  end

  defp send_last_response(session_id, transcript_path) do
    # Try transcript_path from the event, fall back to session's stored path
    path =
      case transcript_path do
        p when is_binary(p) and p != "" -> p
        _ -> get_stored_transcript_path(session_id)
      end

    case TranscriptReader.last_assistant_message(path) do
      {:ok, text} ->
        message = MessageFormatter.assistant_response(text, session_id)
        Telegram.send_message(message)

      :error ->
        :ok
    end
  end

  defp get_stored_transcript_path(session_id) do
    case SessionStore.get_session(session_id) do
      nil -> nil
      session -> session[:transcript_path]
    end
  end

  defp update_session_tty(session_id, working_dir, opts) do
    SessionStore.register_prompt(session_id, "", working_dir, opts)
  end
end

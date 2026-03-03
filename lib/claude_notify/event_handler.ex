defmodule ClaudeNotify.EventHandler do
  require Logger

  alias ClaudeNotify.{
    SessionStore,
    MessageFormatter,
    Telegram,
    TranscriptReader,
    PathSafety,
    Dashboard
  }

  @update_interval 10

  def handle_event(%{"event" => "prompt"} = params) do
    session_id = params["session_id"]
    prompt = params["prompt"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts = params |> Map.take(["tty_path", "term_session_id"]) |> sanitize_opts()
    {action, session} = SessionStore.register_prompt(session_id, prompt, working_dir, opts)

    case action do
      :new_session ->
        message = MessageFormatter.session_started(session)
        notify(message, session_id: session_id)
        Dashboard.refresh()

      :prompt_update ->
        Dashboard.refresh()

        if rem(session.prompt_count, @update_interval) == 0 do
          message = MessageFormatter.session_update(session)
          notify(message, session_id: session_id)
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
        notify(message, session_id: session_id)

      _session ->
        {_action, session} = SessionStore.register_stop(session_id, stop_reason)
        message = MessageFormatter.session_stopped(session)
        notify(message, session_id: session_id)
    end

    Dashboard.refresh()
  end

  def handle_event(%{"event" => "tool_use"} = params) do
    session_id = params["session_id"]
    tool_name = params["tool_name"] || "unknown"
    tool_input = params["tool_input"] || ""
    tool_output = params["tool_output"] || ""
    working_dir = params["working_dir"] || "unknown"

    # Update session with TTY, transcript path, and working_dir
    opts =
      params |> Map.take(["tty_path", "term_session_id", "transcript_path"]) |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    SessionStore.update_status(session_id, :active, %{last_tool: tool_name})

    message = MessageFormatter.tool_use(tool_name, tool_input, tool_output)
    notify(message, session_id: session_id)
  end

  def handle_event(%{"event" => "notification"} = params) do
    session_id = params["session_id"]
    message = params["message"] || ""
    working_dir = params["working_dir"] || "unknown"

    # Update session with TTY, transcript path, and working_dir
    opts =
      params |> Map.take(["tty_path", "term_session_id", "transcript_path"]) |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    SessionStore.update_status(session_id, :waiting_input)

    # Send the last assistant response (Claude's summary before asking)
    send_last_response(session_id, params["transcript_path"])

    text = MessageFormatter.notification_question(message, session_id)

    # Detect numbered options (multi-choice) vs simple yes/no
    options = parse_numbered_options(message)

    buttons =
      if options != [] do
        multi_choice_buttons(session_id, options)
      else
        notification_buttons(session_id)
      end

    notify_with_buttons(text, buttons, session_id: session_id)
    Dashboard.refresh()
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

  defp multi_choice_buttons(session_id, options) do
    option_buttons =
      Enum.map(options, fn {num, label} ->
        short_label = String.slice(label, 0, 40)
        ["#{num}. #{short_label}", "#{session_id}:opt_#{num}"]
      end)

    # Add Esc button at the end
    option_buttons ++ [["Esc", "#{session_id}:escape"]]
  end

  defp parse_numbered_options(message) when is_binary(message) do
    message
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(\d+)\.\s+(.+)$/, String.trim(line)) do
        [_, num, text] -> [{num, String.trim(text)}]
        _ -> []
      end
    end)
  end

  defp parse_numbered_options(_), do: []

  defp send_last_response(session_id, transcript_path) do
    # Try transcript_path from the event, fall back to session's stored path
    path =
      case transcript_path do
        p when is_binary(p) and p != "" -> PathSafety.sanitize_transcript_path(p)
        _ -> get_stored_transcript_path(session_id)
      end

    case TranscriptReader.last_assistant_message(path) do
      {:ok, text} ->
        message = MessageFormatter.assistant_response(text, session_id)
        notify(message, session_id: session_id)

      :error ->
        :ok
    end
  end

  defp get_stored_transcript_path(session_id) do
    case SessionStore.get_session(session_id) do
      nil -> nil
      session -> PathSafety.sanitize_transcript_path(session[:transcript_path])
    end
  end

  defp update_session_tty(session_id, working_dir, opts) do
    SessionStore.update_session_metadata(session_id, working_dir, opts)
  end

  defp sanitize_opts(opts) do
    Map.update(opts, "transcript_path", nil, &PathSafety.sanitize_transcript_path/1)
  end

  defp notify(message, context) do
    case Telegram.send_message_with_retry(message) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send failed: #{inspect(reason)}", context)
        {:error, reason}
    end
  end

  defp notify_with_buttons(text, buttons, context) do
    case Telegram.send_with_buttons_retry(text, buttons) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send_with_buttons failed: #{inspect(reason)}", context)
        {:error, reason}
    end
  end
end

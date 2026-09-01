defmodule ClaudeNotify.EventHandler do
  require Logger

  alias ClaudeNotify.{
    SessionStore,
    MessageFormatter,
    Telegram,
    ActivityTracker,
    TaskTracker,
    Dashboard,
    ProjectScope,
    MemoryCapture,
    Continuity
  }

  def handle_event(%{"event" => "session_start"} = params) do
    session_id = params["session_id"]
    working_dir = params["working_dir"] || "unknown"

    opts =
      params
      |> Map.take(["tty_path", "term_session_id", "transcript_path", "engine"])
      |> attach_project_scope(session_id, working_dir)
      |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    SessionStore.update_status(session_id, :idle, %{session_source: params["source"]})
    checkpoint_transcript(session_id, params["transcript_path"])
    MemoryCapture.terminal(params, SessionStore.get_session(session_id))
    Dashboard.refresh()
    :ok
  end

  def handle_event(%{"event" => "prompt"} = params) do
    session_id = params["session_id"]
    prompt = params["prompt"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts =
      params
      |> Map.take(["tty_path", "term_session_id", "transcript_path", "engine"])
      |> attach_project_scope(session_id, working_dir)
      |> sanitize_opts()

    {action, session} = SessionStore.register_prompt(session_id, prompt, working_dir, opts)
    MemoryCapture.terminal(params, session)

    case action do
      :new_session ->
        message = MessageFormatter.session_started_compact(session)
        notify_and_register(message, session_id)
        Dashboard.refresh()

      :prompt_update ->
        Dashboard.refresh()
        :ok
    end

    # A Telegram-authored prompt is already visible in the chat. Claim it as
    # this turn's reply target instead of sending a duplicate bot echo.
    send_prompt_echo(session_id, prompt)
    checkpoint_transcript(session_id, params["transcript_path"])
  end

  def handle_event(%{"event" => "stop"} = params) do
    session_id = params["session_id"]
    stop_reason = params["stop_reason"] || "unknown"
    working_dir = params["working_dir"] || "unknown"
    git_diff = params["git_diff"]
    transcript_path = params["transcript_path"]

    opts =
      params
      |> Map.take(["tty_path", "term_session_id", "transcript_path", "engine"])
      |> attach_project_scope(session_id, working_dir)
      |> sanitize_opts()

    # A Stop hook can be the first event observed after this service restarts.
    # Seed/update the terminal metadata so the now-idle session remains listed.
    update_session_tty(session_id, working_dir, opts)

    ActivityTracker.end_session(session_id)
    TaskTracker.end_session(session_id)

    # React 👍 or 😱 based on stop reason
    react_on_stop(session_id, stop_reason)

    # Resolve transcript path: from params or from session store
    resolved_transcript = resolve_transcript_path(transcript_path, session_id)

    transcript_messages = drain_transcript(session_id, resolved_transcript)

    fallback_messages =
      deliver_assistant_candidates(session_id, [nonempty(params["assistant_response"])])

    delivered_messages = transcript_messages ++ fallback_messages

    assistant_response =
      nonempty(params["assistant_response"]) ||
        List.last(transcript_messages) ||
        latest_assistant_history(session_id)

    session_before_stop = SessionStore.get_session(session_id)

    params
    |> Map.put("assistant_response", assistant_response || "")
    |> MemoryCapture.terminal(session_before_stop)

    Continuity.terminal(session_before_stop, :turn_stop)

    {_action, session} = SessionStore.register_stop(session_id, stop_reason)
    maybe_send_diff(git_diff, session_id)

    if delivered_messages == [] do
      message = MessageFormatter.session_stopped_compact(session)
      notify_and_register(message, session_id)
    end

    Dashboard.refresh()
  end

  def handle_event(%{"event" => "session_end"} = params) do
    session_id = params["session_id"]
    session = SessionStore.get_session(session_id)
    MemoryCapture.terminal(params, session)
    Continuity.terminal(session, :session_end)
    SessionStore.remove_session(session_id)
    ActivityTracker.end_session(session_id)
    TaskTracker.end_session(session_id)
    Dashboard.refresh()
    :ok
  end

  def handle_event(%{"event" => "tool_use"} = params) do
    session_id = params["session_id"]
    tool_name = params["tool_name"] || "unknown"
    tool_input = params["tool_input"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts =
      params
      |> Map.take(["tty_path", "term_session_id", "transcript_path", "engine"])
      |> attach_project_scope(session_id, working_dir)
      |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    SessionStore.update_status(session_id, :active, %{last_tool: tool_name})
    MemoryCapture.terminal(params, SessionStore.get_session(session_id))
    drain_transcript(session_id, params["transcript_path"])

    # React 🔥 on prompt message to show Claude is working
    maybe_react_tool(session_id)

    # Send rich card for structural tools
    maybe_send_structural_card(tool_name, tool_input, session_id)

    detail = extract_tool_detail(tool_name, tool_input)
    project = session_id |> SessionStore.get_session() |> ProjectScope.display_name()

    ActivityTracker.track_tool(session_id, %{
      project: project,
      tool_name: tool_name,
      tool_detail: detail
    })
  end

  def handle_event(%{"event" => "notification"} = params) do
    session_id = params["session_id"]
    message = params["message"] || ""
    working_dir = params["working_dir"] || "unknown"
    git_diff = params["git_diff"]

    opts =
      params
      |> Map.take(["tty_path", "term_session_id", "transcript_path", "engine"])
      |> attach_project_scope(session_id, working_dir)
      |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    MemoryCapture.terminal(params, SessionStore.get_session(session_id))
    drain_transcript(session_id, params["transcript_path"])

    ActivityTracker.pause_session(session_id)
    SessionStore.update_status(session_id, :waiting_input)
    SessionStore.append_history(session_id, :question, message)

    maybe_send_diff(git_diff, session_id)

    engine = session_engine(session_id)
    text = MessageFormatter.notification_question(message, session_id, engine)
    truncated? = MessageFormatter.notification_truncated?(message)

    # Detect numbered options (multi-choice) vs simple yes/no
    options = parse_numbered_options(message)

    buttons =
      if options != [] do
        multi_choice_buttons(session_id, options)
      else
        notification_buttons(session_id)
      end

    buttons =
      if truncated?,
        do: [["📄 See more", "more:#{session_id}"] | buttons],
        else: buttons

    notification_result =
      notify_with_buttons_and_register(text, buttons, session_id,
        full_text:
          if(truncated?,
            do: MessageFormatter.notification_question_full(message, session_id, engine)
          )
      )

    case notification_result do
      {:ok, message_id} ->
        SessionStore.update_status(session_id, :waiting_input, %{
          pending_question_message_id: message_id
        })

      _other ->
        :ok
    end

    Dashboard.refresh()
  end

  def handle_event(params) do
    Logger.warning("Unknown event: #{inspect(params)}")
    {:error, :unknown_event}
  end

  # -- Private helpers --

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

  defp maybe_send_diff(nil, _session_id), do: :ok
  defp maybe_send_diff("", _session_id), do: :ok

  defp maybe_send_diff(git_diff, session_id) when is_binary(git_diff) do
    case MessageFormatter.diff_summary(git_diff) do
      nil -> :ok
      message -> notify_and_register(message, session_id)
    end
  end

  defp update_session_tty(session_id, working_dir, opts) do
    SessionStore.update_session_metadata(session_id, working_dir, opts)
  end

  defp sanitize_opts(opts), do: opts

  defp notify_and_register(message, session_id) do
    case Telegram.send_message_with_retry(message) do
      {:ok, %{"result" => %{"message_id" => mid}}} ->
        SessionStore.register_message(mid, session_id)
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send failed: #{inspect(reason)}", session_id: session_id)
        {:error, reason}
    end
  end

  defp notify_with_buttons_and_register(text, buttons, session_id, opts) do
    case Telegram.send_with_buttons_retry(text, buttons) do
      {:ok, %{"result" => %{"message_id" => mid}}} ->
        SessionStore.register_message(mid, session_id)

        case Keyword.get(opts, :full_text) do
          full when is_binary(full) -> SessionStore.register_notification_text(mid, full)
          _ -> :ok
        end

        {:ok, mid}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send_with_buttons failed: #{inspect(reason)}",
          session_id: session_id
        )

        {:error, reason}
    end
  end

  defp attach_project_scope(opts, session_id, working_dir) do
    case SessionStore.get_session(session_id) do
      %{working_dir: ^working_dir, project_scope: scope} when not is_nil(scope) ->
        Map.put(opts, "project_scope", scope)

      _session ->
        case ProjectScope.resolve(working_dir) do
          {:ok, scope} -> Map.put(opts, "project_scope", scope)
          {:error, _reason} -> opts
        end
    end
  end

  defp send_prompt_echo(session_id, prompt) when is_binary(prompt) and prompt != "" do
    case SessionStore.claim_telegram_prompt(session_id, prompt) do
      {:ok, mid} ->
        Telegram.set_message_reaction(mid, "👀")
        :ok

      :none ->
        message = MessageFormatter.prompt_echo(prompt)

        case Telegram.send_message_with_retry(message) do
          {:ok, %{"result" => %{"message_id" => mid}}} ->
            SessionStore.register_message(mid, session_id)
            SessionStore.set_prompt_message_id(session_id, mid)
            Telegram.set_message_reaction(mid, "👀")
            :ok

          _ ->
            :ok
        end
    end
  end

  defp send_prompt_echo(_session_id, _prompt), do: :ok

  defp maybe_react_tool(session_id) do
    case SessionStore.get_prompt_message_id(session_id) do
      nil -> :ok
      mid -> Telegram.set_message_reaction(mid, "🔥")
    end
  end

  defp react_on_stop(session_id, stop_reason) do
    case SessionStore.get_prompt_message_id(session_id) do
      nil ->
        :ok

      mid ->
        emoji = if stop_reason in ["error", "crash"], do: "😱", else: "👍"
        Telegram.set_message_reaction(mid, emoji)
    end
  end

  defp resolve_transcript_path(path, _session_id) when is_binary(path) and path != "" do
    ClaudeNotify.PathSafety.sanitize_transcript_path(path)
  end

  defp resolve_transcript_path(_, session_id) do
    case SessionStore.get_session(session_id) do
      %{transcript_path: path} when is_binary(path) and path != "" ->
        ClaudeNotify.PathSafety.sanitize_transcript_path(path)

      _ ->
        nil
    end
  end

  defp checkpoint_transcript(session_id, transcript_path) do
    case resolve_transcript_path(transcript_path, session_id) do
      nil ->
        :ok

      path ->
        case ClaudeNotify.TranscriptReader.position(path) do
          {:ok, cursor} -> SessionStore.checkpoint_transcript(session_id, path, cursor)
          :error -> :ok
        end
    end
  end

  defp drain_transcript(session_id, transcript_path) do
    case resolve_transcript_path(transcript_path, session_id) do
      nil ->
        []

      path ->
        session = SessionStore.get_session(session_id) || %{}

        cursor =
          if session[:transcript_cursor_path] == path,
            do: session[:transcript_cursor],
            else: nil

        case ClaudeNotify.TranscriptReader.assistant_messages_since(path, cursor) do
          {:ok, messages, next_cursor} ->
            case SessionStore.record_assistant_messages(
                   session_id,
                   path,
                   next_cursor,
                   messages
                 ) do
              {:ok, accepted} ->
                Enum.each(accepted, &notify_agent_response(&1, session_id))
                accepted

              {:error, :not_found} ->
                []
            end

          :error ->
            []
        end
    end
  end

  defp deliver_assistant_candidates(session_id, candidates) do
    session = SessionStore.get_session(session_id) || %{}
    path = session[:transcript_cursor_path] || session[:transcript_path] || ""
    cursor = session[:transcript_cursor] || 0

    messages = Enum.reject(candidates, &is_nil/1)

    case SessionStore.record_assistant_messages(session_id, path, cursor, messages) do
      {:ok, accepted} ->
        Enum.each(accepted, &notify_agent_response(&1, session_id))
        accepted

      {:error, :not_found} ->
        []
    end
  end

  defp latest_assistant_history(session_id) do
    session_id
    |> SessionStore.history(12)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, text: text} -> text
      _entry -> nil
    end)
  end

  defp nonempty(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonempty(_text), do: nil

  defp notify_agent_response(text, session_id) do
    message = MessageFormatter.agent_response_html(text, session_engine(session_id))
    notify_html_and_register(message, session_id)
  end

  defp session_engine(session_id) do
    case SessionStore.get_session(session_id) do
      %{engine: engine} when engine in ["claude", "codex"] -> engine
      _ -> "claude"
    end
  end

  defp notify_html_and_register(message, session_id) do
    opts =
      case SessionStore.get_prompt_message_id(session_id) do
        mid when is_integer(mid) -> [reply_to_message_id: mid]
        _ -> []
      end

    case Telegram.send_html_with_retry(message, opts) do
      {:ok, %{"result" => %{"message_id" => mid}}} ->
        SessionStore.register_message(mid, session_id)
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram HTML send failed: #{inspect(reason)}", session_id: session_id)
        {:error, reason}
    end
  end

  # -- Structural tool cards --

  defp maybe_send_structural_card("Skill", tool_input, session_id) do
    skill_name = extract_json_value(tool_input, "skill") || "unknown"
    args = extract_json_value(tool_input, "args")
    message = MessageFormatter.skill_card(skill_name, args)
    notify_and_register(message, session_id)
  end

  defp maybe_send_structural_card("Task", tool_input, session_id) do
    # Only send card if it's an agent delegation (has subagent_type)
    agent_type = extract_json_value(tool_input, "subagent_type")

    if agent_type do
      description = extract_json_value(tool_input, "description")
      message = MessageFormatter.agent_delegation_card(agent_type, description)
      notify_and_register(message, session_id)
    end
  end

  defp maybe_send_structural_card("EnterPlanMode", _tool_input, session_id) do
    message = MessageFormatter.plan_mode_card(:enter)
    notify_and_register(message, session_id)
  end

  defp maybe_send_structural_card("ExitPlanMode", _tool_input, session_id) do
    message = MessageFormatter.plan_mode_card(:exit)
    notify_and_register(message, session_id)
  end

  defp maybe_send_structural_card("TaskCreate", tool_input, session_id) do
    subject = extract_json_value(tool_input, "subject") || "Unknown task"
    TaskTracker.track_create(session_id, %{subject: subject})
  end

  defp maybe_send_structural_card("TaskUpdate", tool_input, session_id) do
    subject = extract_json_value(tool_input, "subject")
    status = extract_json_value(tool_input, "status")

    if subject && status do
      TaskTracker.track_update(session_id, %{subject: subject, status: status})
    end
  end

  defp maybe_send_structural_card(_tool_name, _tool_input, _session_id), do: :ok

  # -- Tool detail extraction --

  defp extract_tool_detail(tool_name, tool_input) when tool_name in ["Read", "Write", "Edit"] do
    extract_json_value(tool_input, "file_path") || truncate_input(tool_input)
  end

  defp extract_tool_detail("Bash", tool_input) do
    extract_json_value(tool_input, "command") || truncate_input(tool_input)
  end

  defp extract_tool_detail("Glob", tool_input) do
    extract_json_value(tool_input, "pattern") || truncate_input(tool_input)
  end

  defp extract_tool_detail("Grep", tool_input) do
    extract_json_value(tool_input, "pattern") || truncate_input(tool_input)
  end

  defp extract_tool_detail("Task", tool_input) do
    desc = extract_json_value(tool_input, "description") || ""
    agent = extract_json_value(tool_input, "subagent_type") || ""
    if agent != "", do: "#{agent}: #{desc}", else: desc
  end

  defp extract_tool_detail(_, tool_input), do: truncate_input(tool_input)

  defp extract_json_value(input, field) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, map} when is_map(map) -> Map.get(map, field)
      _ -> nil
    end
  end

  defp extract_json_value(_, _), do: nil

  defp truncate_input(input) when is_binary(input), do: String.slice(input, 0, 100)
  defp truncate_input(input), do: to_string(input) |> String.slice(0, 100)
end

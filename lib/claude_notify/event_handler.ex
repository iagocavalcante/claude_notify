defmodule ClaudeNotify.EventHandler do
  require Logger

  alias ClaudeNotify.{
    SessionStore,
    MessageFormatter,
    Telegram,
    ActivityTracker,
    TaskTracker,
    Dashboard
  }

  def handle_event(%{"event" => "prompt"} = params) do
    session_id = params["session_id"]
    prompt = params["prompt"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts = params |> Map.take(["tty_path", "term_session_id"]) |> sanitize_opts()
    {action, session} = SessionStore.register_prompt(session_id, prompt, working_dir, opts)

    case action do
      :new_session ->
        message = MessageFormatter.session_started_compact(session)
        notify_and_register(message, session_id)
        Dashboard.refresh()

      :prompt_update ->
        Dashboard.refresh()
        :ok
    end

    # Send prompt echo on every prompt (not just new sessions)
    send_prompt_echo(session_id, prompt)
  end

  def handle_event(%{"event" => "stop"} = params) do
    session_id = params["session_id"]
    stop_reason = params["stop_reason"] || "unknown"
    working_dir = params["working_dir"] || "unknown"
    git_diff = params["git_diff"]
    transcript_path = params["transcript_path"]

    ActivityTracker.end_session(session_id)
    TaskTracker.end_session(session_id)

    # React 👍 or 😱 based on stop reason
    react_on_stop(session_id, stop_reason)

    # Resolve transcript path: from params or from session store
    resolved_transcript = resolve_transcript_path(transcript_path, session_id)

    # Send Claude's response before the session-ended message
    send_claude_response(resolved_transcript, session_id)

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

        maybe_send_diff(git_diff, session_id)
        message = MessageFormatter.session_stopped_compact(session)
        notify_and_register(message, session_id)

      _session ->
        {_action, session} = SessionStore.register_stop(session_id, stop_reason)
        maybe_send_diff(git_diff, session_id)
        message = MessageFormatter.session_stopped_compact(session)
        notify_and_register(message, session_id)
    end

    Dashboard.refresh()
  end

  def handle_event(%{"event" => "tool_use"} = params) do
    session_id = params["session_id"]
    tool_name = params["tool_name"] || "unknown"
    tool_input = params["tool_input"] || ""
    working_dir = params["working_dir"] || "unknown"

    opts =
      params |> Map.take(["tty_path", "term_session_id"]) |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)
    SessionStore.update_status(session_id, :active, %{last_tool: tool_name})

    # React 🔥 on prompt message to show Claude is working
    maybe_react_tool(session_id)

    # Send rich card for structural tools
    maybe_send_structural_card(tool_name, tool_input, session_id)

    detail = extract_tool_detail(tool_name, tool_input)
    project = project_name(working_dir)

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
      params |> Map.take(["tty_path", "term_session_id"]) |> sanitize_opts()

    update_session_tty(session_id, working_dir, opts)

    ActivityTracker.pause_session(session_id)
    SessionStore.update_status(session_id, :waiting_input)

    maybe_send_diff(git_diff, session_id)

    text = MessageFormatter.notification_question(message, session_id)

    # Detect numbered options (multi-choice) vs simple yes/no
    options = parse_numbered_options(message)

    buttons =
      if options != [] do
        multi_choice_buttons(session_id, options)
      else
        notification_buttons(session_id)
      end

    notify_with_buttons_and_register(text, buttons, session_id)
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

  defp notify_with_buttons_and_register(text, buttons, session_id) do
    case Telegram.send_with_buttons_retry(text, buttons) do
      {:ok, %{"result" => %{"message_id" => mid}}} ->
        SessionStore.register_message(mid, session_id)
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram send_with_buttons failed: #{inspect(reason)}",
          session_id: session_id
        )

        {:error, reason}
    end
  end

  defp project_name(dir) when is_binary(dir), do: Path.basename(dir)
  defp project_name(_), do: "unknown"

  defp send_prompt_echo(session_id, prompt) when is_binary(prompt) and prompt != "" do
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

  defp send_claude_response(nil, _session_id), do: :ok

  defp send_claude_response(transcript_path, session_id) do
    case ClaudeNotify.TranscriptReader.last_assistant_message(transcript_path) do
      {:ok, text} ->
        message = MessageFormatter.claude_response(text)
        notify_and_register(message, session_id)

      :error ->
        :ok
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

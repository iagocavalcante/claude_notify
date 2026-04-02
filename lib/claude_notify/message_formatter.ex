defmodule ClaudeNotify.MessageFormatter do
  @doc """
  Format a notification question message (for permission prompts, etc.).
  """
  def notification_question(message, session_id) do
    truncated = truncate(message, 500)
    short_id = String.slice(session_id, 0, 8)

    [
      "*Claude Code Question*",
      "",
      escape(truncated),
      "",
      "Session: `#{escape_code(short_id)}`"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format a user prompt echo message.
  """
  def prompt_echo(prompt) do
    truncated = truncate(prompt, 500)
    "💬 *You*\n> #{escape(truncated)}"
  end

  @max_response_chars 2000

  @doc """
  Format Claude's response message for Telegram.
  """
  def claude_response(text) do
    if String.length(text) > @max_response_chars do
      truncated = String.slice(text, 0, @max_response_chars)
      remaining = String.length(text) - @max_response_chars
      "🤖 *Claude*\n#{escape(truncated)}\n\n_…truncated \\(#{remaining} more chars\\)_"
    else
      "🤖 *Claude*\n#{escape(text)}"
    end
  end

  @doc """
  Format a skill invocation card.
  """
  def skill_card(skill_name, description) do
    desc_line =
      if description && description != "",
        do: "\n   #{escape(truncate(description, 100))}",
        else: ""

    "🎯 *Using skill:* #{escape(skill_name)}#{desc_line}"
  end

  @doc """
  Format an agent delegation card.
  """
  def agent_delegation_card(agent_type, description) do
    desc_line =
      if description && description != "",
        do: "\n   \"#{escape(truncate(description, 100))}\"",
        else: ""

    "🤖 → *#{escape(agent_type)}* agent#{desc_line}"
  end

  @doc """
  Format a plan mode entry/exit card.
  """
  def plan_mode_card(:enter), do: "📝 *Entering plan mode*"
  def plan_mode_card(:exit), do: "📝 *Exiting plan mode*"

  @doc """
  Format a task checklist for edit-in-place display.
  """
  def task_checklist(tasks) do
    if tasks == [] do
      "📋 *Tasks*\n   _No tasks yet_"
    else
      lines =
        Enum.map(tasks, fn task ->
          icon =
            case task.status do
              :completed -> "✅"
              :in_progress -> "🔄"
              _ -> "⬜"
            end

          "   #{icon} #{escape(truncate(task.subject, 60))}"
        end)

      "📋 *Tasks*\n#{Enum.join(lines, "\n")}"
    end
  end

  defp project_name(dir) when is_binary(dir), do: Path.basename(dir)
  defp project_name(_), do: "unknown"

  defp truncate(nil, _max), do: ""
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining = rem(seconds, 60)

    if minutes < 60 do
      "#{minutes}m #{remaining}s"
    else
      hours = div(minutes, 60)
      remaining_min = rem(minutes, 60)
      "#{hours}h #{remaining_min}m"
    end
  end

  @doc """
  Format a compact "session started" message.
  """
  def session_started_compact(session) do
    project = project_name(session.working_dir)
    dir = escape_code(session.working_dir)
    "🟢 #{escape(project)} · started\nDirectory: `#{dir}`"
  end

  @doc """
  Format a compact "session stopped" message.
  """
  def session_stopped_compact(session) do
    project = project_name(session.working_dir)

    duration =
      if session[:started_at] && session[:stopped_at] do
        format_duration(session.stopped_at - session.started_at)
      else
        "unknown"
      end

    reason = session[:stop_reason] || "unknown"
    count = session[:prompt_count] || 0

    "🔴 #{escape(project)} · ended\nDuration: #{escape(duration)} · #{count} prompts · reason: #{escape(reason)}"
  end

  @doc """
  Format an edit-in-place activity status message.
  """
  def activity_message(state) do
    files = state.files_touched |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
    current = format_current_tool(state[:current_tool], state[:current_detail])

    [
      "⚙️ #{escape(state.project)}",
      "━━━━━━━━━━━━━━━",
      "Actions: #{state.action_count}",
      "Files touched: #{escape(files)}",
      current
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Format an edit-in-place activity status message for waiting/approval state.
  """
  def activity_message_waiting(state) do
    files = state.files_touched |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

    [
      "⏸️ #{escape(state.project)}",
      "━━━━━━━━━━━━━━━",
      "Actions: #{state.action_count}",
      "Files touched: #{escape(files)}",
      "Waiting for approval\\.\\.\\."
    ]
    |> Enum.join("\n")
  end

  @max_diff_chars 3000

  @doc """
  Format a git diff summary message. Returns nil for empty/nil input.
  """
  def diff_summary(nil), do: nil
  def diff_summary(""), do: nil

  def diff_summary(diff_text) when is_binary(diff_text) do
    trimmed = String.trim(diff_text)
    if trimmed == "", do: nil, else: format_diff(trimmed)
  end

  defp format_diff(diff_text) do
    if byte_size(diff_text) > @max_diff_chars do
      stat_line = diff_text |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")
      safe = escape_pre(String.slice(stat_line, 0, @max_diff_chars))

      "📋 *Changes since last checkpoint*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n```\n#{safe}\n```\n\n_Diff too large, showing summary only_"
    else
      safe = escape_pre(diff_text)
      "📋 *Changes since last checkpoint*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n```\n#{safe}\n```"
    end
  end

  defp format_current_tool(nil, _), do: nil

  defp format_current_tool(tool, detail) do
    label = tool_action_label(tool)
    if detail, do: "#{label}: #{escape(truncate(detail, 80))}", else: label
  end

  defp tool_action_label("Bash"), do: "Running"
  defp tool_action_label("Read"), do: "Reading"
  defp tool_action_label("Write"), do: "Writing"
  defp tool_action_label("Edit"), do: "Editing"
  defp tool_action_label("Glob"), do: "Searching"
  defp tool_action_label("Grep"), do: "Searching"
  defp tool_action_label("Task"), do: "Delegating"
  defp tool_action_label(tool), do: escape(tool)

  @doc """
  Public escape for MarkdownV2 plain text (outside entities).
  """
  def escape_full(text), do: escape(text)

  @doc """
  Public escape for MarkdownV2 code spans.
  """
  def escape_code_public(text), do: escape_code(text)

  # Inside MarkdownV2 pre blocks (```), only backtick and backslash need escaping
  defp escape_pre(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
  end

  defp escape_pre(text), do: escape_pre(to_string(text))

  # Inside MarkdownV2 code spans, only backtick and backslash need escaping
  defp escape_code(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
  end

  defp escape_code(text), do: escape_code(to_string(text))

  # Outside entities, all MarkdownV2 special chars must be escaped
  @special_chars [
    "_",
    "*",
    "[",
    "]",
    "(",
    ")",
    "~",
    "`",
    ">",
    "#",
    "+",
    "-",
    "=",
    "|",
    "{",
    "}",
    ".",
    "!"
  ]
  defp escape(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> then(fn t ->
      Enum.reduce(@special_chars, t, fn char, acc ->
        String.replace(acc, char, "\\#{char}")
      end)
    end)
  end

  defp escape(text), do: escape(to_string(text))
end

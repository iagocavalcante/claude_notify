defmodule ClaudeNotify.MessageFormatter do
  @doc """
  Format a "new session started" message.
  """
  def session_started(session) do
    project = project_name(session.working_dir)
    prompt = truncate(session.first_prompt, 200)

    [
      "*New Claude Code Session*",
      "",
      "Project: `#{escape_code(project)}`",
      "Directory: `#{escape_code(session.working_dir)}`",
      "First prompt: `#{escape_code(prompt)}`"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format a periodic session update message.
  """
  def session_update(session) do
    project = project_name(session.working_dir)
    duration = format_duration(System.system_time(:second) - session.started_at)

    [
      "*Session Update*",
      "",
      "Project: `#{escape_code(project)}`",
      "Prompts: #{session.prompt_count}",
      "Duration: #{escape(duration)}"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format a "session stopped" message.
  """
  def session_stopped(session) do
    project = project_name(session.working_dir)

    duration =
      if session[:started_at] && session[:stopped_at] do
        format_duration(session.stopped_at - session.started_at)
      else
        "unknown"
      end

    reason = session[:stop_reason] || "unknown"

    [
      "*Session Ended*",
      "",
      "Project: `#{escape_code(project)}`",
      "Reason: `#{escape_code(reason)}`",
      "Total prompts: #{session[:prompt_count] || 0}",
      "Duration: #{escape(duration)}"
    ]
    |> Enum.join("\n")
  end

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
  Format Claude's final response/summary message.
  """
  def assistant_response(text, session_id) do
    truncated = truncate(text, 1500)
    short_id = String.slice(session_id, 0, 8)

    # Wrap in pre block — only backticks and backslashes need escaping inside
    safe_text = escape_pre(truncated)

    [
      "*Claude Response*",
      "",
      "```\n#{safe_text}\n```",
      "",
      "Session: `#{escape_code(short_id)}`"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format a tool use message showing what Claude Code just did.
  """
  def tool_use(tool_name, tool_input, tool_output) do
    icon = tool_icon(tool_name)
    detail = tool_detail(tool_name, tool_input)
    output_line = format_tool_output(tool_output)

    lines = [
      "#{escape(icon)} *#{escape(tool_name)}*",
      "`#{escape_code(detail)}`"
    ]

    lines =
      if output_line != "" do
        lines ++ ["", escape(output_line)]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp tool_icon("Read"), do: "📖"
  defp tool_icon("Write"), do: "📝"
  defp tool_icon("Edit"), do: "✏️"
  defp tool_icon("Bash"), do: "💻"
  defp tool_icon("Glob"), do: "🔍"
  defp tool_icon("Grep"), do: "🔎"
  defp tool_icon("Task"), do: "🤖"
  defp tool_icon("WebFetch"), do: "🌐"
  defp tool_icon("WebSearch"), do: "🌐"
  defp tool_icon(_), do: "🔧"

  defp tool_detail("Read", input), do: extract_json_field(input, "file_path", input)
  defp tool_detail("Write", input), do: extract_json_field(input, "file_path", input)
  defp tool_detail("Edit", input), do: extract_json_field(input, "file_path", input)
  defp tool_detail("Bash", input), do: extract_json_field(input, "command", input)
  defp tool_detail("Glob", input), do: extract_json_field(input, "pattern", input)
  defp tool_detail("Grep", input), do: extract_json_field(input, "pattern", input)

  defp tool_detail("Task", input) do
    desc = extract_json_field(input, "description", "")
    agent = extract_json_field(input, "subagent_type", "")
    if agent != "", do: "#{agent}: #{desc}", else: desc
  end

  defp tool_detail(_tool, input), do: truncate(input, 100)

  defp extract_json_field(input, field, default) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, map} when is_map(map) -> truncate(Map.get(map, field, to_string(default)), 150)
      _ -> truncate(input, 150)
    end
  end

  defp extract_json_field(input, _field, _default), do: truncate(to_string(input), 150)

  defp format_tool_output(nil), do: ""
  defp format_tool_output(""), do: ""
  defp format_tool_output("\"\""), do: ""

  defp format_tool_output(output) when is_binary(output) do
    clean =
      output
      |> String.replace(~r/^"|"$/, "")
      |> String.trim()

    if clean == "" do
      ""
    else
      truncate(clean, 150)
    end
  end

  defp format_tool_output(output), do: truncate(to_string(output), 150)

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

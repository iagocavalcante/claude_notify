defmodule ClaudeNotify.MessageFormatter do
  @notification_truncate_at 500

  @doc """
  Format a notification question message (for permission prompts, etc.).
  Truncates messages over #{@notification_truncate_at} chars; use
  `notification_question_full/2` for the un-truncated version.
  """
  def notification_question(message, session_id, engine \\ "claude") do
    build_notification(truncate(message, @notification_truncate_at), session_id, engine)
  end

  @doc """
  Like `notification_question/2` but does not truncate the body — used by
  the See more expansion path.
  """
  def notification_question_full(message, session_id, engine \\ "claude") do
    build_notification(message || "", session_id, engine)
  end

  @doc """
  True when `notification_question/2` would truncate this message.
  """
  def notification_truncated?(message) when is_binary(message),
    do: byte_size(message) > @notification_truncate_at

  def notification_truncated?(_), do: false

  defp build_notification(body, session_id, engine) do
    short_id = String.slice(session_id, 0, 8)

    [
      "*#{agent_name(engine)} Question*",
      "",
      escape(body),
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
  Formats an assistant response as Telegram HTML while preserving the useful
  subset of Markdown coding agents commonly emit: headings, bold/italic text,
  bullets, quotes, links, inline code, and fenced code blocks.

  HTML is used deliberately for agent-authored content. Telegram's MarkdownV2
  syntax differs from CommonMark, so escaping a normal agent response either
  exposes literal `**markers**` or produces fragile nested escaping.
  """
  def claude_response_html(text) do
    body = agent_markdown_html(text)
    "🤖 <b>Claude</b>\n#{body}"
  end

  @doc "Formats an interactive terminal agent response for Telegram HTML."
  def agent_response_html(text, engine) do
    body = agent_markdown_html(text)
    "🤖 <b>#{html_escape(agent_name(engine))}</b>\n#{body}"
  end

  @doc """
  Converts CommonMark-style agent text into safe Telegram HTML.

  All source HTML is escaped before supported Markdown markers are converted,
  so model output cannot inject arbitrary Telegram tags or attributes.
  """
  def agent_markdown_html(text) when is_binary(text) do
    rendered = text |> String.split("\n") |> render_markdown_lines()
    if valid_telegram_html?(rendered), do: rendered, else: html_escape(text)
  end

  def agent_markdown_html(text), do: text |> to_string() |> agent_markdown_html()

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
    project = ClaudeNotify.ProjectScope.display_name(session)
    dir = escape_code(session.working_dir)
    "🟢 #{escape(project)} · #{escape(agent_name(session[:engine]))} started\nDirectory: `#{dir}`"
  end

  @doc """
  Format a compact turn-completed message. Claude Code's Stop hook means the
  assistant is idle and ready for another prompt; it does not mean the terminal
  session has closed.
  """
  def session_stopped_compact(session) do
    project = ClaudeNotify.ProjectScope.display_name(session)

    duration =
      if session[:started_at] && session[:stopped_at] do
        format_duration(session.stopped_at - session.started_at)
      else
        "unknown"
      end

    reason = session[:stop_reason] || "unknown"
    count = session[:prompt_count] || 0

    "⚪ #{escape(project)} · #{escape(agent_name(session[:engine]))} idle\nSession time: #{escape(duration)} · #{count} prompts · last turn: #{escape(reason)}"
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

  Never truncates: the full diff is wrapped in a fenced pre block, however
  large. Splitting oversized output into multiple Telegram messages is the
  sending layer's job (see `ClaudeNotify.Telegram.chunk/2`, used by
  `send_message_with_retry/2`) - silently cutting the diff here would hide
  real changes from the "Show diff" button instead of showing all of them
  across more than one message.
  """
  def diff_summary(nil), do: nil
  def diff_summary(""), do: nil

  def diff_summary(diff_text) when is_binary(diff_text) do
    trimmed = String.trim(diff_text)
    if trimmed == "", do: nil, else: format_diff(trimmed)
  end

  defp format_diff(diff_text) do
    safe = pre_block_full(diff_text)
    "📋 *Changes since last checkpoint*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n#{safe}"
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
  Format a dispatcher job's completion report: a completed header, the
  engine's own final summary (or a placeholder if it didn't report one),
  and the worktree's diffstat since the job branched off (or nothing, if
  there's nothing to diff). Buttons (Show diff / Create PR / Discard) are
  built and attached by the caller - this only returns the message text.
  """
  def job_completed(job, diffstat, summary) do
    [
      "✅ #{escape("Job ##{job.id} (#{job.project}, #{job.engine}) completed")}",
      "━━━━━━━━━━━━━━━",
      summary_line(summary),
      diffstat_block(diffstat)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  HTML counterpart to `job_completed/3` for agent-authored summaries.
  """
  def job_completed_html(job, diffstat, summary) do
    summary_html =
      case summary do
        nil -> "<i>No summary reported</i>"
        "" -> "<i>No summary reported</i>"
        text -> bounded_agent_markdown_html(text, 2_500)
      end

    diff_html =
      case diffstat do
        nil -> nil
        "" -> nil
        text -> "<pre>#{bounded_html_escape(text, 900)}</pre>"
      end

    [
      "✅ <b>#{html_escape(job.project)}</b> · #{html_escape(engine_name(job.engine))}",
      "<code>Job ##{html_escape(job.id)} · completed</code>",
      "",
      summary_html,
      diff_html
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Format a dispatcher job's failure report: a failed header and the tail of
  the engine's own output - never a green-washed success-shaped message.
  `error_text` is the job's persisted `error_tail` (the engine's own error
  message if it reported one, otherwise the tail of its raw stdout).
  Buttons (Show output / Discard) are built and attached by the caller.
  """
  def job_failed(job, error_text) do
    [
      "❌ #{escape("Job ##{job.id} (#{job.project}, #{job.engine}) failed")}",
      "━━━━━━━━━━━━━━━",
      error_block(error_text)
    ]
    |> Enum.join("\n")
  end

  @doc """
  HTML counterpart to `job_failed/2`.
  """
  def job_failed_html(job, error_text) do
    error_html =
      case error_text do
        nil -> "<i>No output captured</i>"
        "" -> "<i>No output captured</i>"
        text -> "<pre>#{bounded_html_escape(text, 2_600)}</pre>"
      end

    [
      "❌ <b>#{html_escape(job.project)}</b> · #{html_escape(engine_name(job.engine))}",
      "<code>Job ##{html_escape(job.id)} · failed</code>",
      "",
      error_html
    ]
    |> Enum.join("\n")
  end

  @doc """
  Format raw job output/error text for the "Show output" button, using the
  same pre-block convention as `diff_summary/1` - unbounded, like
  `diff_summary/1`, so the sending layer's chunking (not this function)
  decides how a long error tail is split across messages. Returns a
  placeholder (never nil) since this always renders as its own standalone
  message.
  """
  def job_output_block(text), do: pre_block_full(text) || escape("No output captured.")

  @doc """
  Format the reply for watching an already-terminal job whose transcript
  was already discarded (see `ClaudeNotify.JobTranscript`'s discard-on-
  completion lifecycle, driven by `ClaudeNotify.JobRunner`) - never claims
  the job is still being watched.
  """
  def transcript_unavailable(job) do
    escape("Job ##{job.id}: transcript gone (job ended before watching).")
  end

  @max_transcript_chars 4_096
  @transcript_truncation_notice "_earlier entries truncated_\n\n"

  @doc """
  Format a watched job's transcript message: a header plus its recorded
  `ClaudeNotify.JobTranscript.transcript/3` entries (oldest first) - a
  `:text` entry as escaped plain text, a `:tool_use` entry as a tool/file
  label plus its captured diff rendered in the same fenced `pre_block/1`
  style already used for `job_completed/3`'s diffstat.

  Bounded to Telegram's 4096-char message limit: when the full render
  doesn't fit, the OLDEST entries are dropped first - newest content
  always wins - and a truncation marker is added. Always renders
  something for a non-empty `entries` list, byte-truncating a single
  oversized entry (never splitting a UTF-8 codepoint) if even the newest
  entry alone doesn't fit.
  """
  def transcript_message(job, []) do
    transcript_header(job) <> escape("(no output yet)")
  end

  def transcript_message(job, entries) do
    header = transcript_header(job)
    blocks = Enum.map(entries, &render_transcript_entry/1)
    newest_first = Enum.reverse(blocks)
    budget = @max_transcript_chars - byte_size(header)

    {kept, kept_count} = take_transcript_blocks(newest_first, budget)

    if kept_count < length(blocks) do
      truncated_budget = max(budget - byte_size(@transcript_truncation_notice), 0)
      {kept_truncated, _count} = take_transcript_blocks(newest_first, truncated_budget)
      header <> @transcript_truncation_notice <> Enum.join(kept_truncated, "\n\n")
    else
      header <> Enum.join(kept, "\n\n")
    end
  end

  defp transcript_header(job) do
    "👀 " <>
      escape("Job ##{job.id} (#{job.project}, #{job.engine}) - transcript") <>
      "\n━━━━━━━━━━━━━━━\n\n"
  end

  defp render_transcript_entry(%{type: :text, text: text}), do: escape(text)

  defp render_transcript_entry(%{type: :tool_use, name: name, file_path: nil}) do
    escape("🔧 #{name}")
  end

  defp render_transcript_entry(%{type: :tool_use, name: name, file_path: file_path, diff: diff}) do
    label = escape("🔧 #{name}: #{file_path}")

    case pre_block(diff) do
      nil -> label
      block -> label <> "\n" <> block
    end
  end

  # Keeps the longest NEWEST-first prefix of `blocks` (each preceded by a
  # "\n\n" separator, except the first) that fits within `budget` bytes,
  # returned already in oldest-first order - ready for a direct
  # `Enum.join/2` - so newer entries are always favored when not
  # everything fits. Always keeps at least one (byte-truncated if
  # necessary) block, so a non-empty transcript never renders as empty.
  defp take_transcript_blocks([], _budget), do: {[], 0}

  defp take_transcript_blocks([newest | rest], budget) do
    fitted = fit_transcript_block(newest, budget)
    accumulate_transcript_blocks(rest, budget - byte_size(fitted), [fitted], 1)
  end

  defp accumulate_transcript_blocks([], _remaining, acc, count), do: {acc, count}

  defp accumulate_transcript_blocks([block | rest], remaining, acc, count) do
    needed = byte_size(block) + 2

    if needed <= remaining do
      accumulate_transcript_blocks(rest, remaining - needed, [block | acc], count + 1)
    else
      {acc, count}
    end
  end

  defp fit_transcript_block(block, budget) when byte_size(block) <= budget, do: block

  defp fit_transcript_block(block, budget) do
    block
    |> binary_part(0, max(budget, 0))
    |> valid_utf8_transcript_prefix()
  end

  defp valid_utf8_transcript_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_utf8_transcript_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp summary_line(nil), do: escape("(no summary reported)")
  defp summary_line(""), do: escape("(no summary reported)")
  defp summary_line(text), do: escape(truncate(text, 500))

  defp diffstat_block(text), do: pre_block(text)

  defp error_block(text), do: pre_block(text) || escape("(no output captured)")

  defp pre_block(nil), do: nil
  defp pre_block(""), do: nil

  defp pre_block(text) when is_binary(text) do
    safe = text |> truncate(@max_diff_chars) |> escape_pre()
    "```\n#{safe}\n```"
  end

  # Same fenced-pre-block rendering as `pre_block/1`, but without its
  # `@max_diff_chars` cap - for content whose length is bounded by the
  # sending layer's chunking instead of by this formatter (`diff_summary/1`,
  # `job_output_block/1`). `pre_block/1` itself stays capped: it backs
  # `job_completed/3`/`job_failed/2`, which are edited in place alongside
  # buttons - a single Telegram message that can't be split into chunks.
  defp pre_block_full(nil), do: nil
  defp pre_block_full(""), do: nil

  defp pre_block_full(text) when is_binary(text) do
    safe = escape_pre(text)
    "```\n#{safe}\n```"
  end

  @doc """
  Public escape for MarkdownV2 plain text (outside entities).
  """
  def escape_full(text), do: escape(text)

  @doc """
  Public escape for MarkdownV2 code spans.
  """
  def escape_code_public(text), do: escape_code(text)

  @doc false
  def html_escape_public(text), do: html_escape(text)

  defp bounded_agent_markdown_html(text, max_bytes) do
    source = to_string(text)
    render_bounded_markdown(source, max_bytes, min(String.length(source), 2_800))
  end

  defp render_bounded_markdown(source, max_bytes, char_limit) do
    truncated? = String.length(source) > char_limit
    rendered = source |> String.slice(0, char_limit) |> agent_markdown_html()
    suffix = if truncated?, do: "\n\n<i>…response truncated</i>", else: ""

    cond do
      byte_size(rendered <> suffix) <= max_bytes ->
        rendered <> suffix

      char_limit > 120 ->
        render_bounded_markdown(source, max_bytes, max(div(char_limit * 3, 4), 120))

      true ->
        bounded_html_escape(source, max_bytes - 32) <> "\n<i>…truncated</i>"
    end
  end

  defp render_markdown_lines(lines) do
    {rendered, code_lines} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, code_lines} ->
        cond do
          is_list(code_lines) and fenced_code_line?(line) ->
            code = code_lines |> Enum.reverse() |> Enum.join("\n") |> html_escape()
            {["<pre>#{code}</pre>" | acc], nil}

          is_list(code_lines) ->
            {acc, [line | code_lines]}

          fenced_code_line?(line) ->
            {acc, []}

          true ->
            {[render_markdown_line(line) | acc], nil}
        end
      end)

    rendered =
      case code_lines do
        nil ->
          rendered

        unclosed ->
          [
            "<pre>#{unclosed |> Enum.reverse() |> Enum.join("\n") |> html_escape()}</pre>"
            | rendered
          ]
      end

    rendered |> Enum.reverse() |> Enum.join("\n")
  end

  defp fenced_code_line?(line), do: Regex.match?(~r/^\s*```[^`]*\s*$/, line)

  defp render_markdown_line(line) do
    cond do
      match = Regex.run(~r/^\s{0,3}[#]{1,6}\s+(.+)$/, line) ->
        [_, content] = match
        "<b>#{render_inline_markdown(content)}</b>"

      match = Regex.run(~r/^\s*[-+*]\s+(.+)$/, line) ->
        [_, content] = match
        "• #{render_inline_markdown(content)}"

      match = Regex.run(~r/^\s*(\d+)[.)]\s+(.+)$/, line) ->
        [_, number, content] = match
        "<b>#{number}.</b> #{render_inline_markdown(content)}"

      match = Regex.run(~r/^\s*>\s?(.*)$/, line) ->
        [_, content] = match
        "<blockquote>#{render_inline_markdown(content)}</blockquote>"

      true ->
        render_inline_markdown(line)
    end
  end

  defp render_inline_markdown(text) do
    ~r/(`[^`\n]+`|\[[^\]\n]+\]\(https?:\/\/[A-Za-z0-9._~:\/?#\[\]@!$&'()+,;=%-]+\))/
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map(fn part ->
      cond do
        Regex.match?(~r/^`[^`\n]+`$/, part) ->
          "<code>#{part |> String.slice(1, String.length(part) - 2) |> html_escape()}</code>"

        match = Regex.run(~r/^\[([^\]\n]+)\]\((https?:\/\/.+)\)$/, part) ->
          [_, label, url] = match
          "<a href=\"#{html_escape(url)}\">#{html_escape(label)}</a>"

        true ->
          part
          |> html_escape()
          |> replace_regex(~r/\*\*(.+?)\*\*/, "<b>\\1</b>")
          |> replace_regex(~r/__(.+?)__/, "<b>\\1</b>")
          |> replace_regex(~r/~~(.+?)~~/, "<s>\\1</s>")
          |> replace_regex(~r/(?<!\*)\*([^*\n]+)\*(?!\*)/, "<i>\\1</i>")
          |> replace_regex(~r/(?<!\w)_([^_\n]+)_(?!\w)/, "<i>\\1</i>")
      end
    end)
    |> Enum.join()
  end

  defp bounded_html_escape(text, max_bytes) do
    text
    |> to_string()
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      escaped = html_escape(grapheme)
      escaped_size = byte_size(escaped)

      if size + escaped_size <= max(max_bytes, 0),
        do: {:cont, {[escaped | acc], size + escaped_size}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp replace_regex(text, regex, replacement), do: Regex.replace(regex, text, replacement)

  @telegram_html_tags ~w(b i s code pre blockquote a)

  defp valid_telegram_html?(html) do
    tags = Regex.scan(~r/<(\/)?([a-z]+)(?:\s+[^>]*)?>/, html)

    case Enum.reduce_while(tags, [], fn
           [_, "", tag], stack when tag in @telegram_html_tags ->
             {:cont, [tag | stack]}

           [_, "/", tag], [tag | rest] when tag in @telegram_html_tags ->
             {:cont, rest}

           _tag, _stack ->
             {:halt, :invalid}
         end) do
      [] -> true
      _ -> false
    end
  end

  defp html_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp engine_name("claude"), do: "Claude"
  defp engine_name("codex"), do: "Codex"
  defp engine_name(other), do: to_string(other)

  defp agent_name("codex"), do: "Codex"
  defp agent_name(_), do: "Claude Code"

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

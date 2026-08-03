defmodule ClaudeNotify.MessageFormatterTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.MessageFormatter

  test "session_started_compact formats minimal start message" do
    session = %{working_dir: "/Users/iago/projects/my_app"}
    message = MessageFormatter.session_started_compact(session)
    assert message =~ "🟢"
    assert message =~ "my_app"
    assert message =~ "started"
  end

  test "session_stopped_compact formats minimal stop message" do
    now = System.system_time(:second)

    session = %{
      working_dir: "/Users/iago/projects/my_app",
      prompt_count: 8,
      started_at: now - 754,
      stopped_at: now,
      stop_reason: "user_quit"
    }

    message = MessageFormatter.session_stopped_compact(session)
    assert message =~ "⚪"
    assert message =~ "my\\_app"
    assert message =~ "idle"
    assert message =~ "12m"
    assert message =~ "8 prompts"
    assert message =~ "user\\_quit"
  end

  test "activity_message formats edit-in-place status" do
    state = %{
      project: "my_app",
      action_count: 14,
      files_touched: MapSet.new(["router.ex", "config.ex", "test.ex"]),
      current_tool: "Bash",
      current_detail: "mix test"
    }

    message = MessageFormatter.activity_message(state)
    assert message =~ "⚙️"
    assert message =~ "my\\_app"
    assert message =~ "14"
    assert message =~ "router\\.ex"
    assert message =~ "Running: mix test"
  end

  test "activity_message_waiting formats paused state" do
    state = %{project: "my_app", action_count: 14, files_touched: MapSet.new(["router.ex"])}
    message = MessageFormatter.activity_message_waiting(state)
    assert message =~ "⏸️"
    assert message =~ "Waiting for approval"
  end

  test "diff_summary formats git diff output" do
    diff_text =
      " 2 files changed, 10 insertions(+), 3 deletions(-)\n\n--- a/lib/router.ex\n+++ b/lib/router.ex\n@@ -1,3 +1,5 @@\n-old line\n+new line\n+another line"

    message = MessageFormatter.diff_summary(diff_text)
    assert message =~ "📋"
    assert message =~ "Changes since last checkpoint"
    assert message =~ "old line"
    assert message =~ "new line"
  end

  test "diff_summary never truncates - splitting oversized diffs into multiple messages is the sending layer's job" do
    huge_diff = String.duplicate("+ added line\n", 500)
    message = MessageFormatter.diff_summary(huge_diff)
    assert byte_size(message) > 4096
    assert message =~ String.trim_trailing(huge_diff)
    refute message =~ "Diff too large"
  end

  test "diff_summary returns nil for empty diff" do
    assert MessageFormatter.diff_summary("") == nil
    assert MessageFormatter.diff_summary(nil) == nil
  end

  test "prompt_echo formats user prompt as quoted message" do
    message = MessageFormatter.prompt_echo("Add error handling to the login endpoint")
    assert message =~ "💬"
    assert message =~ "You"
    assert message =~ "Add error handling to the login endpoint"
  end

  test "prompt_echo truncates long prompts" do
    long_prompt = String.duplicate("a", 600)
    message = MessageFormatter.prompt_echo(long_prompt)
    assert message =~ "\\.\\.\\."
    assert String.length(message) < 700
  end

  test "prompt_echo escapes MarkdownV2 special chars" do
    message = MessageFormatter.prompt_echo("fix the user.name [field]")
    assert message =~ "user\\.name"
    assert message =~ "\\[field\\]"
  end

  test "claude_response formats assistant message" do
    message = MessageFormatter.claude_response("I'll add try-catch blocks around the endpoint.")
    assert message =~ "🤖"
    assert message =~ "Claude"
    assert message =~ "try\\-catch"
  end

  test "claude_response truncates at 2000 chars and shows truncation notice" do
    long_text = String.duplicate("word ", 500)
    message = MessageFormatter.claude_response(long_text)
    assert message =~ "_…truncated"
  end

  test "claude_response does not show truncation for short messages" do
    message = MessageFormatter.claude_response("Short response.")
    refute message =~ "truncated"
  end

  test "claude_response escapes MarkdownV2 special chars" do
    message = MessageFormatter.claude_response("Check user.name in [config]")
    assert message =~ "user\\.name"
    assert message =~ "\\[config\\]"
  end

  describe "agent Markdown rendered as Telegram HTML" do
    test "preserves headings, emphasis, lists, links, inline code, and fenced code" do
      markdown = """
      ## Result

      **Done** with *care*.
      - Updated `lib/app.ex`
      - See [the PR](https://example.com/pull/1)

      ```elixir
      assert result == :ok
      ```
      """

      html = MessageFormatter.agent_markdown_html(markdown)

      assert html =~ "<b>Result</b>"
      assert html =~ "<b>Done</b> with <i>care</i>"
      assert html =~ "• Updated <code>lib/app.ex</code>"
      assert html =~ "<a href=\"https://example.com/pull/1\">the PR</a>"
      assert html =~ "<pre>assert result == :ok</pre>"
    end

    test "escapes model-supplied HTML instead of allowing tag injection" do
      html = MessageFormatter.agent_markdown_html("<b>fake</b> & <script>alert(1)</script>")

      assert html =~ "&lt;b&gt;fake&lt;/b&gt;"
      assert html =~ "&amp;"
      refute html =~ "<script>"
    end

    test "falls back safely when nested Markdown would create crossed HTML tags" do
      markdown = "**bold with *nested italic***"
      html = MessageFormatter.agent_markdown_html(markdown)

      assert html == markdown
      refute html =~ "<b>"
      refute html =~ "<i>"
    end

    test "assistant HTML response keeps the complete content for delivery chunking" do
      markdown = String.duplicate("**important & safe**\n", 1_000)
      html = MessageFormatter.claude_response_html(markdown)

      assert byte_size(html) > 4_096
      assert html =~ "<b>Claude</b>"
      assert html =~ "<b>important &amp; safe</b>"
      refute html =~ "response truncated"
    end
  end

  # Rich tool card tests

  test "skill_card formats skill invocation" do
    message =
      MessageFormatter.skill_card("brainstorming", "Exploring requirements before implementation")

    assert message =~ "🎯"
    assert message =~ "brainstorming"
    assert message =~ "Exploring requirements"
  end

  test "skill_card with nil description" do
    message = MessageFormatter.skill_card("commit", nil)
    assert message =~ "🎯"
    assert message =~ "commit"
  end

  test "agent_delegation_card formats agent spawn" do
    message = MessageFormatter.agent_delegation_card("Explore", "Find all auth middleware files")
    assert message =~ "🤖"
    assert message =~ "Explore"
    assert message =~ "Find all auth middleware"
  end

  test "agent_delegation_card with nil description" do
    message = MessageFormatter.agent_delegation_card("general-purpose", nil)
    assert message =~ "🤖"
    assert message =~ "general\\-purpose"
  end

  test "plan_mode_card formats plan entry" do
    message = MessageFormatter.plan_mode_card(:enter)
    assert message =~ "📝"
    assert message =~ "plan"
  end

  test "plan_mode_card formats plan exit" do
    message = MessageFormatter.plan_mode_card(:exit)
    assert message =~ "📝"
  end

  test "task_checklist formats task list" do
    tasks = [
      %{subject: "Read existing auth code", status: :completed},
      %{subject: "Write integration tests", status: :in_progress},
      %{subject: "Update API docs", status: :pending}
    ]

    message = MessageFormatter.task_checklist(tasks)
    assert message =~ "📋"
    assert message =~ "✅"
    assert message =~ "🔄"
    assert message =~ "⬜"
    assert message =~ "Read existing auth code"
    assert message =~ "Write integration tests"
    assert message =~ "Update API docs"
  end

  test "task_checklist with empty list" do
    message = MessageFormatter.task_checklist([])
    assert message =~ "📋"
  end

  # Job report tests (story #235)

  @job %{id: 7, project: "trainer", engine: "claude"}

  test "job_completed formats a completed header, summary, and diffstat" do
    diffstat = " lib/foo.ex | 3 +++\n 1 file changed, 3 insertions(+)"
    message = MessageFormatter.job_completed(@job, diffstat, "Added a helper function")

    assert message =~ "✅"
    assert message =~ "7"
    assert message =~ "trainer"
    assert message =~ "completed"
    assert message =~ "Added a helper function"
    assert message =~ "lib/foo.ex"
  end

  test "job_completed with no diffstat omits the diff block" do
    message = MessageFormatter.job_completed(@job, nil, "Nothing to change")
    assert message =~ "Nothing to change"
    refute message =~ "```"
  end

  test "job_completed with no summary shows a placeholder" do
    message = MessageFormatter.job_completed(@job, nil, nil)
    assert message =~ "no summary reported"
  end

  test "job_failed formats a failed header and the error text" do
    message = MessageFormatter.job_failed(@job, "boom: something broke")

    assert message =~ "❌"
    assert message =~ "7"
    assert message =~ "failed"
    assert message =~ "boom: something broke"
  end

  test "job_failed with no error text shows a placeholder, never green-washed" do
    message = MessageFormatter.job_failed(@job, nil)
    assert message =~ "failed"
    assert message =~ "no output captured"
  end

  test "job completion HTML renders the agent summary instead of exposing Markdown markers" do
    message =
      MessageFormatter.job_completed_html(
        @job,
        "lib/foo.ex | 2 ++",
        "## Finished\n\n- Added **validation**\n- Ran `mix test`"
      )

    assert message =~ "<b>trainer</b> · Claude"
    assert message =~ "<b>Finished</b>"
    assert message =~ "• Added <b>validation</b>"
    assert message =~ "• Ran <code>mix test</code>"
    assert message =~ "<pre>lib/foo.ex | 2 ++</pre>"
    refute message =~ "**validation**"
    assert byte_size(message) <= 4_096
  end

  test "job_output_block wraps text in a pre block" do
    message = MessageFormatter.job_output_block("line one\nline two")
    assert message =~ "```"
    assert message =~ "line one"
    assert message =~ "line two"
  end

  test "job_output_block with nil shows a placeholder" do
    message = MessageFormatter.job_output_block(nil)
    assert message =~ "No output captured"
  end

  # Watch mode transcript rendering (story #238)

  test "transcript_unavailable reports the job id and never claims to be watching" do
    message = MessageFormatter.transcript_unavailable(@job)
    assert message =~ "7"
    assert message =~ "gone"
  end

  test "transcript_message with no entries shows a waiting placeholder" do
    message = MessageFormatter.transcript_message(@job, [])
    assert message =~ "trainer"
    assert message =~ "no output yet"
  end

  test "transcript_message renders :text entries in order" do
    entries = [
      %{type: :text, text: "first update", at: 1},
      %{type: :text, text: "second update", at: 2}
    ]

    message = MessageFormatter.transcript_message(@job, entries)

    assert message =~ "first update"
    assert message =~ "second update"
    first_index = :binary.match(message, "first update") |> elem(0)
    second_index = :binary.match(message, "second update") |> elem(0)
    assert first_index < second_index
  end

  test "transcript_message renders a :tool_use entry's diff in the existing consolidated-diff (fenced pre block) style" do
    entry = %{
      type: :tool_use,
      name: "Edit",
      file_path: "lib/foo.ex",
      diff: "-old line\n+new line",
      at: 1
    }

    message = MessageFormatter.transcript_message(@job, [entry])

    assert message =~ "Edit"
    assert message =~ "foo\\.ex"
    assert message =~ "```"
    assert message =~ "old line"
    assert message =~ "new line"
  end

  test "transcript_message renders a :tool_use entry with no diff, no pre block" do
    entry = %{type: :tool_use, name: "Read", file_path: "lib/foo.ex", diff: nil, at: 1}
    message = MessageFormatter.transcript_message(@job, [entry])

    assert message =~ "Read"
    refute message =~ "```"
  end

  test "transcript_message never exceeds Telegram's 4096-char limit and keeps the newest entries when over budget" do
    oldest = %{type: :text, text: "OLDESTMARKER " <> String.duplicate("a", 2000), at: 1}
    middle = %{type: :text, text: "MIDDLEMARKER " <> String.duplicate("b", 2000), at: 2}
    newest = %{type: :text, text: "NEWESTMARKER " <> String.duplicate("c", 2000), at: 3}

    message = MessageFormatter.transcript_message(@job, [oldest, middle, newest])

    assert byte_size(message) <= 4096
    assert message =~ "NEWESTMARKER"
    assert message =~ "truncated"
    refute message =~ "OLDESTMARKER"
  end

  # Hostile-content escaping for the job/watch rich cards (story #241).
  #
  # Two different escaping rules apply depending on where content lands:
  # outside a MarkdownV2 entity (headers, summaries, tool/file names) every
  # special character in `escape/1`'s list must be backslash-escaped, but
  # INSIDE a fenced ``` pre block (diffstat/error/diff/transcript-diff
  # content) only backtick and backslash need it - Telegram treats
  # everything else in a code span/block literally. Getting this wrong in
  # either direction either breaks Telegram's parser (`can't parse
  # entities`) or double-escapes/mangles legitimate code content.
  describe "hostile content escaping (story #241 rich cards)" do
    @hostile_job %{id: 9, project: "trainer_*app*", engine: "claude[v2]"}

    test "job_completed fully escapes the header/summary but only backtick/backslash inside the diffstat's pre block" do
      diffstat = "-old`code`\n+new_code(v2)"
      summary = "Fixed the *login* bug in [auth].ex!"

      message = MessageFormatter.job_completed(@hostile_job, diffstat, summary)

      assert message =~ "trainer\\_\\*app\\*"
      assert message =~ "claude\\[v2\\]"
      assert message =~ "Fixed the \\*login\\* bug in \\[auth\\]\\.ex\\!"
      assert message =~ "```\n-old\\`code\\`\n+new_code(v2)\n```"
    end

    test "job_failed fully escapes the header but only backtick/backslash inside the error pre block" do
      error_text = "panic: nil.foo() at `lib/bar.ex:10` [uncaught]"

      message = MessageFormatter.job_failed(@hostile_job, error_text)

      assert message =~ "trainer\\_\\*app\\*"
      assert message =~ "```\npanic: nil.foo() at \\`lib/bar.ex:10\\` [uncaught]\n```"
    end

    test "job_output_block escapes only backtick/backslash, preserving every other metacharacter literally, never truncated" do
      hostile =
        "line1 with * and _ and [brackets]\nline2 with a `backtick` and a \\backslash"

      message = MessageFormatter.job_output_block(hostile)

      assert message =~ "```"
      assert message =~ "line1 with * and _ and [brackets]"
      assert message =~ "\\`backtick\\`"
      assert message =~ "\\\\backslash"
    end

    test "diff_summary escapes only backtick/backslash inside its pre block, never truncated" do
      hostile_diff = "-old\n+new `code` with *stars* and [brackets] and a \\backslash"
      message = MessageFormatter.diff_summary(hostile_diff)

      assert message =~ "```"
      assert message =~ "+new \\`code\\` with *stars* and [brackets] and a \\\\backslash"
    end

    test "transcript_message escapes hostile tool names/file paths outside entities, and hostile diffs only backtick/backslash inside their pre block" do
      entry = %{
        type: :tool_use,
        name: "Edit[v2]",
        file_path: "lib/foo_bar.ex",
        diff: "-old `code`\n+new_code",
        at: 1
      }

      message = MessageFormatter.transcript_message(@hostile_job, [entry])

      assert message =~ "Edit\\[v2\\]"
      assert message =~ "foo\\_bar\\.ex"
      assert message =~ "```\n-old \\`code\\`\n+new_code\n```"
    end
  end

  describe "notification_truncated?/1" do
    test "false for short messages" do
      refute MessageFormatter.notification_truncated?("hello")
      refute MessageFormatter.notification_truncated?("")
      refute MessageFormatter.notification_truncated?(nil)
    end

    test "true once message exceeds 500 bytes" do
      assert MessageFormatter.notification_truncated?(String.duplicate("a", 501))
    end

    test "boundary at exactly 500 bytes" do
      refute MessageFormatter.notification_truncated?(String.duplicate("a", 500))
    end
  end

  describe "notification_question_full/2" do
    test "does not truncate even very long messages" do
      long = String.duplicate("a", 1500)
      result = MessageFormatter.notification_question_full(long, "abc12345")
      # MarkdownV2 doesn't escape 'a', so the body length is unchanged
      assert result =~ String.duplicate("a", 1500)
    end
  end
end

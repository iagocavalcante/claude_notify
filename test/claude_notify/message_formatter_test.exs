defmodule ClaudeNotify.MessageFormatterTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.MessageFormatter

  test "session_started formats new session message" do
    session = %{
      id: "sess-1",
      working_dir: "/Users/iago/projects/my_app",
      prompt_count: 1,
      first_prompt: "Fix the login bug",
      started_at: System.system_time(:second)
    }

    message = MessageFormatter.session_started(session)

    assert message =~ "*New Claude Code Session*"
    assert message =~ "`my_app`"
    assert message =~ "Fix the login bug"
  end

  test "session_update formats update message" do
    session = %{
      id: "sess-1",
      working_dir: "/Users/iago/projects/my_app",
      prompt_count: 10,
      started_at: System.system_time(:second) - 300
    }

    message = MessageFormatter.session_update(session)

    assert message =~ "*Session Update*"
    assert message =~ "10"
    assert message =~ "5m"
  end

  test "session_stopped formats stop message" do
    now = System.system_time(:second)

    session = %{
      id: "sess-1",
      working_dir: "/Users/iago/projects/my_app",
      prompt_count: 5,
      started_at: now - 600,
      stopped_at: now,
      stop_reason: "user_quit"
    }

    message = MessageFormatter.session_stopped(session)

    assert message =~ "*Session Ended*"
    assert message =~ "user_quit"
    assert message =~ "5"
    assert message =~ "10m"
  end

  test "session_started handles special characters in code spans" do
    session = %{
      id: "sess-1",
      working_dir: "/Users/iago/my.project",
      prompt_count: 1,
      first_prompt: "Fix bug #123 (urgent!)",
      started_at: System.system_time(:second)
    }

    message = MessageFormatter.session_started(session)

    # Code spans don't need MarkdownV2 escaping (only backtick/backslash)
    assert message =~ "`my.project`"
    assert message =~ "Fix bug #123 (urgent!)"
  end

  test "session_started truncates long prompts" do
    long_prompt = String.duplicate("a", 300)

    session = %{
      id: "sess-1",
      working_dir: "/tmp/test",
      prompt_count: 1,
      first_prompt: long_prompt,
      started_at: System.system_time(:second)
    }

    message = MessageFormatter.session_started(session)
    assert message =~ "..."
  end

  # --- New compact / activity / diff tests ---

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
    assert message =~ "🔴"
    assert message =~ "my\\_app"
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

  test "diff_summary truncates large diffs" do
    huge_diff = String.duplicate("+ added line\n", 500)
    message = MessageFormatter.diff_summary(huge_diff)
    assert byte_size(message) <= 4096
    assert message =~ "Diff too large"
  end

  test "diff_summary returns nil for empty diff" do
    assert MessageFormatter.diff_summary("") == nil
    assert MessageFormatter.diff_summary(nil) == nil
  end
end

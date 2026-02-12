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
end

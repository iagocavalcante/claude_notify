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
end

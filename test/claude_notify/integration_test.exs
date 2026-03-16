defmodule ClaudeNotify.IntegrationTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{EventHandler, SessionStore}

  setup do
    SessionStore.clear()
    :ok
  end

  test "full quiet-mode session flow doesn't crash" do
    # 1. Session starts
    EventHandler.handle_event(%{
      "event" => "prompt",
      "session_id" => "integ-1",
      "prompt" => "Fix the login bug",
      "working_dir" => "/tmp/test-project"
    })

    assert SessionStore.get_session("integ-1") != nil

    # 2. Several tool uses (should go to ActivityTracker, not Telegram directly)
    for tool <- ["Read", "Grep", "Edit", "Bash"] do
      EventHandler.handle_event(%{
        "event" => "tool_use",
        "session_id" => "integ-1",
        "working_dir" => "/tmp/test-project",
        "tool_name" => tool,
        "tool_input" => ~s({"file_path":"lib/foo.ex"}),
        "tool_output" => ""
      })
    end

    # 3. Permission prompt with diff
    EventHandler.handle_event(%{
      "event" => "notification",
      "session_id" => "integ-1",
      "working_dir" => "/tmp/test-project",
      "message" => "Allow bash: mix test?",
      "git_diff" => " 1 file changed, +5 -2\n-old\n+new"
    })

    # 4. More tool uses after approval
    EventHandler.handle_event(%{
      "event" => "tool_use",
      "session_id" => "integ-1",
      "working_dir" => "/tmp/test-project",
      "tool_name" => "Bash",
      "tool_input" => ~s({"command":"mix test"}),
      "tool_output" => "3 tests, 0 failures"
    })

    # 5. Session ends with diff
    EventHandler.handle_event(%{
      "event" => "stop",
      "session_id" => "integ-1",
      "stop_reason" => "user_quit",
      "working_dir" => "/tmp/test-project",
      "git_diff" => " 2 files changed, +10 -3"
    })

    assert SessionStore.get_session("integ-1") == nil
  end

  test "session without git diff still works" do
    EventHandler.handle_event(%{
      "event" => "prompt",
      "session_id" => "integ-2",
      "prompt" => "Hello",
      "working_dir" => "/tmp/no-git"
    })

    EventHandler.handle_event(%{
      "event" => "notification",
      "session_id" => "integ-2",
      "working_dir" => "/tmp/no-git",
      "message" => "Allow?",
      "git_diff" => ""
    })

    EventHandler.handle_event(%{
      "event" => "stop",
      "session_id" => "integ-2",
      "stop_reason" => "user_quit",
      "working_dir" => "/tmp/no-git",
      "git_diff" => ""
    })

    assert SessionStore.get_session("integ-2") == nil
  end
end

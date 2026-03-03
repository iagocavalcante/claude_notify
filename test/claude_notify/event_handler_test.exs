defmodule ClaudeNotify.EventHandlerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{EventHandler, SessionStore}

  setup do
    SessionStore.clear()
    :ok
  end

  test "handle_event with prompt event registers session" do
    params = %{
      "event" => "prompt",
      "session_id" => "test-sess",
      "prompt" => "hello world",
      "working_dir" => "/tmp/test"
    }

    EventHandler.handle_event(params)

    session = SessionStore.get_session("test-sess")
    assert session != nil
    assert session.prompt_count == 1
  end

  test "handle_event with stop event removes session" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    params = %{
      "event" => "stop",
      "session_id" => "test-sess",
      "stop_reason" => "user_quit"
    }

    EventHandler.handle_event(params)

    assert SessionStore.get_session("test-sess") == nil
  end

  test "handle_event with stop for untracked session still sends notification" do
    params = %{
      "event" => "stop",
      "session_id" => "unknown-sess",
      "stop_reason" => "user_quit",
      "working_dir" => "/tmp/project"
    }

    # Should not crash, sends notification with event data
    result = EventHandler.handle_event(params)
    assert result != {:error, :unknown_event}
  end

  test "handle_event with unknown event returns error" do
    result = EventHandler.handle_event(%{"event" => "unknown_event"})
    assert result == {:error, :unknown_event}
  end

  test "tool_use metadata updates do not inflate prompt_count" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    EventHandler.handle_event(%{
      "event" => "tool_use",
      "session_id" => "test-sess",
      "working_dir" => "/tmp/test",
      "tool_name" => "Read",
      "tool_input" => ~s({"file_path":"lib/foo.ex"}),
      "tool_output" => "",
      "tty_path" => "/dev/ttys001"
    })

    session = SessionStore.get_session("test-sess")
    assert session.prompt_count == 1
    assert session.tty_path == "/dev/ttys001"
  end

  test "transcript_path outside allowed roots is discarded" do
    EventHandler.handle_event(%{
      "event" => "notification",
      "session_id" => "test-sess",
      "working_dir" => "/tmp/test",
      "message" => "Need approval",
      "transcript_path" => "/etc/passwd"
    })

    session = SessionStore.get_session("test-sess")
    assert session[:transcript_path] == nil
  end
end

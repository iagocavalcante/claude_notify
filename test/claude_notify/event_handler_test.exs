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
end

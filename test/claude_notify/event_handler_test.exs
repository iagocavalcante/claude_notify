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

    result = EventHandler.handle_event(params)
    assert result != {:error, :unknown_event}
  end

  test "handle_event with unknown event returns error" do
    result = EventHandler.handle_event(%{"event" => "unknown_event"})
    assert result == {:error, :unknown_event}
  end

  test "tool_use event tracks via ActivityTracker" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    EventHandler.handle_event(%{
      "event" => "tool_use",
      "session_id" => "test-sess",
      "working_dir" => "/tmp/test",
      "tool_name" => "Read",
      "tool_input" => ~s({"file_path":"lib/foo.ex"}),
      "tool_output" => ""
    })

    session = SessionStore.get_session("test-sess")
    assert session.prompt_count == 1
  end

  test "notification event updates session status to waiting_input" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    EventHandler.handle_event(%{
      "event" => "notification",
      "session_id" => "test-sess",
      "working_dir" => "/tmp/test",
      "message" => "Allow bash?",
      "git_diff" => " 1 file changed\n-old\n+new"
    })

    session = SessionStore.get_session("test-sess")
    assert session.status == :waiting_input
  end

  test "notification with empty git_diff skips diff message" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    EventHandler.handle_event(%{
      "event" => "notification",
      "session_id" => "test-sess",
      "working_dir" => "/tmp/test",
      "message" => "Allow bash?",
      "git_diff" => ""
    })

    session = SessionStore.get_session("test-sess")
    assert session.status == :waiting_input
  end

  test "prompt event sends prompt echo message" do
    params = %{
      "event" => "prompt",
      "session_id" => "echo-sess",
      "prompt" => "Add error handling",
      "working_dir" => "/tmp/test"
    }

    EventHandler.handle_event(params)

    session = SessionStore.get_session("echo-sess")
    assert session != nil
    assert session.prompt_count == 1
  end

  test "subsequent prompt events also send prompt echo" do
    SessionStore.register_prompt("echo-sess", "first", "/tmp/test")

    params = %{
      "event" => "prompt",
      "session_id" => "echo-sess",
      "prompt" => "second prompt",
      "working_dir" => "/tmp/test"
    }

    EventHandler.handle_event(params)

    session = SessionStore.get_session("echo-sess")
    assert session.prompt_count == 2
  end

  test "stop event reads transcript and sends Claude response" do
    transcript_path =
      Path.join("/tmp", "test_transcript_#{System.unique_integer([:positive])}.jsonl")

    assistant_msg =
      Jason.encode!(%{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "I added the error handling."}]
        }
      })

    File.write!(transcript_path, assistant_msg <> "\n")

    # Register session with transcript_path
    SessionStore.register_prompt("transcript-sess", "hello", "/tmp/test")

    SessionStore.update_session_metadata("transcript-sess", "/tmp/test", %{
      "transcript_path" => transcript_path
    })

    params = %{
      "event" => "stop",
      "session_id" => "transcript-sess",
      "stop_reason" => "end_turn",
      "working_dir" => "/tmp/test",
      "transcript_path" => transcript_path
    }

    EventHandler.handle_event(params)
    assert SessionStore.get_session("transcript-sess") == nil

    File.rm(transcript_path)
  end

  test "stop event with git_diff sends diff before session ended" do
    SessionStore.register_prompt("test-sess", "hello", "/tmp/test")

    EventHandler.handle_event(%{
      "event" => "stop",
      "session_id" => "test-sess",
      "stop_reason" => "user_quit",
      "working_dir" => "/tmp/test",
      "git_diff" => " 1 file changed\n-old\n+new"
    })

    assert SessionStore.get_session("test-sess") == nil
  end
end

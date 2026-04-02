defmodule ClaudeNotify.SessionStoreTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.SessionStore

  setup do
    SessionStore.clear()
    :ok
  end

  test "register_prompt creates new session on first prompt" do
    {action, session} = SessionStore.register_prompt("sess-1", "hello", "/tmp/project")

    assert action == :new_session
    assert session.id == "sess-1"
    assert session.prompt_count == 1
    assert session.first_prompt == "hello"
    assert session.working_dir == "/tmp/project"
  end

  test "register_prompt increments count on subsequent prompts" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    {action, session} = SessionStore.register_prompt("sess-1", "world", "/tmp/project")

    assert action == :prompt_update
    assert session.prompt_count == 2
    assert session.first_prompt == "hello"
  end

  test "register_stop removes session and returns stopped info" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    {action, session} = SessionStore.register_stop("sess-1", "user_quit")

    assert action == :stopped
    assert session.stop_reason == "user_quit"
    assert session.prompt_count == 1

    assert SessionStore.get_session("sess-1") == nil
  end

  test "register_stop for unknown session returns minimal info" do
    {action, session} = SessionStore.register_stop("unknown", "crash")

    assert action == :stopped
    assert session.stop_reason == "crash"
    assert session.prompt_count == 0
  end

  test "all_sessions returns active sessions" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/a")
    SessionStore.register_prompt("sess-2", "world", "/tmp/b")

    sessions = SessionStore.all_sessions()
    assert map_size(sessions) == 2
  end

  test "register_message and lookup_session_by_message work" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test")
    SessionStore.register_message(12345, "sess-1")

    assert SessionStore.lookup_session_by_message(12345) == "sess-1"
    assert SessionStore.lookup_session_by_message(99999) == nil
  end

  test "message mappings are cleaned up when session is removed" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test")
    SessionStore.register_message(12345, "sess-1")
    SessionStore.register_stop("sess-1", "user_quit")

    assert SessionStore.lookup_session_by_message(12345) == nil
  end

  test "update_session_metadata does not increment prompt_count" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")

    {_action, updated} =
      SessionStore.update_session_metadata("sess-1", "/tmp/project", %{
        "tty_path" => "/dev/ttys001"
      })

    assert updated.prompt_count == 1
    assert updated.tty_path == "/dev/ttys001"
  end

  test "set_prompt_message_id and get it back from session" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    SessionStore.set_prompt_message_id("sess-1", 42)

    session = SessionStore.get_session("sess-1")
    assert session.prompt_message_id == 42
  end

  test "set_prompt_message_id for unknown session is a no-op" do
    result = SessionStore.set_prompt_message_id("nonexistent", 42)
    assert result == :not_found
  end
end

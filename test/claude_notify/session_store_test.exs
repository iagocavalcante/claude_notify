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
end

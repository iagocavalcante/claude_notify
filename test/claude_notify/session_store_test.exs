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

  test "register_stop keeps the session idle and returns turn info" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    {action, session} = SessionStore.register_stop("sess-1", "user_quit")

    assert action == :idle
    assert session.stop_reason == "user_quit"
    assert session.prompt_count == 1
    assert session.status == :idle

    assert SessionStore.get_session("sess-1").status == :idle
  end

  test "register_stop for unknown session records a minimal idle session" do
    {action, session} = SessionStore.register_stop("unknown", "crash")

    assert action == :idle
    assert session.stop_reason == "crash"
    assert session.prompt_count == 0
    assert SessionStore.get_session("unknown").status == :idle
  end

  test "all_sessions returns active sessions" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/a")
    SessionStore.register_prompt("sess-2", "world", "/tmp/b")

    sessions = SessionStore.all_sessions()
    assert map_size(sessions) == 2
  end

  test "terminal_sessions excludes headless and unknown sessions" do
    SessionStore.register_prompt("interactive", "hello", "/tmp/a", %{
      "tty_path" => "/dev/ttys004"
    })

    SessionStore.register_prompt("headless", "hello", "/tmp/b")
    SessionStore.register_prompt("unknown", "hello", "/tmp/c", %{"tty_path" => "/dev/ttys005"})

    assert %{"interactive" => %{tty_path: "/dev/ttys004"}} = SessionStore.terminal_sessions()
    refute Map.has_key?(SessionStore.terminal_sessions(), "headless")
    refute Map.has_key?(SessionStore.terminal_sessions(), "unknown")
  end

  test "register_message and lookup_session_by_message work" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test")
    SessionStore.register_message(12345, "sess-1")

    assert SessionStore.lookup_session_by_message(12345) == "sess-1"
    assert SessionStore.lookup_session_by_message(99999) == nil
  end

  test "message mappings remain routable while a session is idle" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test")
    SessionStore.register_message(12345, "sess-1")
    SessionStore.register_stop("sess-1", "user_quit")

    assert SessionStore.lookup_session_by_message(12345) == "sess-1"
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

  test "get_prompt_message_id returns stored id" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    SessionStore.set_prompt_message_id("sess-1", 42)
    assert SessionStore.get_prompt_message_id("sess-1") == 42
  end

  test "get_prompt_message_id returns nil for unknown session" do
    assert SessionStore.get_prompt_message_id("nonexistent") == nil
  end

  test "get_prompt_message_id returns nil when not set" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    assert SessionStore.get_prompt_message_id("sess-1") == nil
  end

  test "register_notification_text and get_notification_text round-trip" do
    SessionStore.register_notification_text(42, "full notification text")
    # Cast then call — call ensures the cast has been processed.
    SessionStore.lookup_session_by_message(0)
    assert SessionStore.get_notification_text(42) == "full notification text"
  end

  test "get_notification_text returns nil for unknown message_id" do
    assert SessionStore.get_notification_text(999) == nil
  end

  test "notification_text is cleaned up when session stops" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    SessionStore.register_message(42, "sess-1")
    SessionStore.register_notification_text(42, "long permission prompt body")

    SessionStore.register_stop("sess-1", "user_quit")

    assert SessionStore.get_notification_text(42) == nil
  end

  test "remove_session deletes a genuinely closed session and its message mappings" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/project")
    SessionStore.register_message(42, "sess-1")
    SessionStore.lookup_session_by_message(0)

    assert SessionStore.remove_session("sess-1") == :ok
    assert SessionStore.get_session("sess-1") == nil
    assert SessionStore.lookup_session_by_message(42) == nil
    assert SessionStore.remove_session("sess-1") == :not_found
  end

  test "sessions and reply routing survive a store restart" do
    path = Path.join(System.tmp_dir!(), "session-store-#{System.unique_integer([:positive])}.dat")

    {:ok, store} = SessionStore.start_link(name: nil, path: path)

    GenServer.call(store, {
      :register_prompt,
      "persisted",
      "hello",
      "/tmp/project",
      %{"tty_path" => "/dev/ttys006"}
    })

    GenServer.cast(store, {:register_message, 77, "persisted"})
    GenServer.call(store, {:lookup_message, 0})
    GenServer.stop(store)

    {:ok, restored} = SessionStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert %{working_dir: "/tmp/project", tty_path: "/dev/ttys006"} =
             GenServer.call(restored, {:get_session, "persisted"})

    assert GenServer.call(restored, {:lookup_message, 77}) == "persisted"
    File.rm(path)
  end
end

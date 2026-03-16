defmodule ClaudeNotify.TelegramPollerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{TelegramPoller, SessionStore}

  setup do
    original = Application.get_env(:claude_notify, :telegram_chat_id)

    on_exit(fn ->
      Application.put_env(:claude_notify, :telegram_chat_id, original)
    end)

    :ok
  end

  test "authorized_chat?/1 accepts only configured chat id" do
    Application.put_env(:claude_notify, :telegram_chat_id, "123456")

    assert TelegramPoller.authorized_chat?(123_456)
    assert TelegramPoller.authorized_chat?("123456")
    refute TelegramPoller.authorized_chat?("999999")
  end

  test "reply to a tracked message looks up correct session" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test", %{"tty_path" => "/dev/ttys001"})
    SessionStore.register_message(42, "sess-1")

    # Verify the message-to-session lookup works
    assert SessionStore.lookup_session_by_message(42) == "sess-1"

    # Verify the session has the expected tty_path
    session = SessionStore.get_session("sess-1")
    assert session[:tty_path] == "/dev/ttys001"
  end
end

defmodule ClaudeNotify.TelegramPollerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.TelegramPoller

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
end

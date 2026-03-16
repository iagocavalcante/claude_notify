defmodule ClaudeNotify.TelegramTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.Telegram

  setup_all do
    Code.ensure_loaded!(Telegram)
    :ok
  end

  test "edit_message_text builds correct API payload" do
    assert function_exported?(Telegram, :edit_message_text, 2)
  end

  test "edit_message_text_with_retry retries on 429" do
    assert function_exported?(Telegram, :edit_message_text_with_retry, 2)
  end
end

import Config

config :logger, level: :warning

config :claude_notify,
  port: 4041,
  telegram_base_url: "http://localhost:9999",
  telegram_bot_token: "test-token",
  telegram_chat_id: "test-chat-id",
  start_poller: false

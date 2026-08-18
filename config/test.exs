import Config

config :logger, level: :warning

config :claude_notify,
  port: 4041,
  telegram_base_url: "http://localhost:9999",
  telegram_bot_token: "test-token",
  telegram_chat_id: "test-chat-id",
  webhook_secret: "test-webhook-secret",
  webhook_max_skew_seconds: 300,
  max_event_concurrency: 20,
  workspace_roots: [],
  session_store_path: nil,
  memory_store_path: nil,
  preview_store_path: nil,
  keep_awake_while_working: false,
  start_poller: false,
  start_job_reconciler: false

import Config

config :claude_notify,
  port: 4040,
  telegram_base_url: "https://api.telegram.org",
  max_event_concurrency: 8,
  webhook_max_skew_seconds: 300,
  transcript_allowed_roots: ["/tmp", Path.join(System.user_home!(), ".claude")]

import_config "#{config_env()}.exs"

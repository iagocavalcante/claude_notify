import Config

config :claude_notify,
  port: 4040,
  telegram_base_url: "https://api.telegram.org"

import_config "#{config_env()}.exs"

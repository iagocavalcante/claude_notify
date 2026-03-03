import Config

if config_env() != :test do
  parse_int = fn
    nil, default ->
      default

    value, default ->
      case Integer.parse(value) do
        {parsed, ""} -> parsed
        _ -> default
      end
  end

  Dotenvy.source([".env", System.get_env()])

  config :claude_notify,
    telegram_bot_token: Dotenvy.env!("TELEGRAM_BOT_TOKEN", :string),
    telegram_chat_id: Dotenvy.env!("TELEGRAM_CHAT_ID", :string),
    webhook_secret: Dotenvy.env!("CLAUDE_NOTIFY_WEBHOOK_SECRET", :string),
    max_event_concurrency: parse_int.(System.get_env("MAX_EVENT_CONCURRENCY"), 8),
    webhook_max_skew_seconds: parse_int.(System.get_env("WEBHOOK_MAX_SKEW_SECONDS"), 300)
end

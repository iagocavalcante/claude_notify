import Config

if config_env() != :test do
  Dotenvy.source([".env", System.get_env()])

  config :claude_notify,
    telegram_bot_token: Dotenvy.env!("TELEGRAM_BOT_TOKEN", :string),
    telegram_chat_id: Dotenvy.env!("TELEGRAM_CHAT_ID", :string)
end

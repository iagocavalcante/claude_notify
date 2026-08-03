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

  parse_bool = fn
    nil, default ->
      default

    value, default when is_binary(value) ->
      case String.downcase(String.trim(value)) do
        value when value in ["1", "true", "yes", "on"] -> true
        value when value in ["0", "false", "no", "off"] -> false
        _ -> default
      end
  end

  Dotenvy.source([".env", System.get_env()])

  workspace_roots =
    Dotenvy.env!(
      "CLAUDE_NOTIFY_WORKSPACE_ROOTS",
      :string,
      Path.join(System.user_home!(), "Workspaces")
    )
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> Path.expand()))

  preview_emails =
    System.get_env("CLOUDFLARE_ACCESS_EMAILS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :claude_notify,
    telegram_bot_token: Dotenvy.env!("TELEGRAM_BOT_TOKEN", :string),
    telegram_chat_id: Dotenvy.env!("TELEGRAM_CHAT_ID", :string),
    webhook_secret: Dotenvy.env!("CLAUDE_NOTIFY_WEBHOOK_SECRET", :string),
    workspace_roots: workspace_roots,
    claude_chrome_enabled: parse_bool.(System.get_env("CLAUDE_NOTIFY_CLAUDE_CHROME"), false),
    preview: %{
      default_provider: System.get_env("CLAUDE_NOTIFY_PREVIEW_PROVIDER", "auto"),
      ttl_seconds:
        parse_int.(
          System.get_env("CLAUDE_NOTIFY_PREVIEW_TTL_SECONDS") ||
            System.get_env("CLOUDFLARE_PREVIEW_TTL_SECONDS"),
          7_200
        ),
      port_start: 41_000,
      port_end: 41_999,
      cloudflare: %{
        api_token: System.get_env("CLOUDFLARE_API_TOKEN"),
        account_id: System.get_env("CLOUDFLARE_ACCOUNT_ID"),
        zone_id: System.get_env("CLOUDFLARE_ZONE_ID"),
        domain: System.get_env("CLOUDFLARE_PREVIEW_DOMAIN"),
        allowed_emails: preview_emails,
        access_session_duration: System.get_env("CLOUDFLARE_ACCESS_SESSION_DURATION", "1h")
      },
      tailscale: %{
        mode: System.get_env("TAILSCALE_PREVIEW_MODE", "serve"),
        tailscale_path: System.get_env("TAILSCALE_PATH", "tailscale"),
        ssh_host: System.get_env("TAILSCALE_SSH_HOST"),
        ssh_path: System.get_env("TAILSCALE_SSH_PATH", "ssh"),
        https_port_start: 44_300,
        https_port_end: 44_399,
        remote_port_start: 45_300,
        remote_port_end: 45_399
      }
    },
    keep_awake_while_working: parse_bool.(System.get_env("CLAUDE_NOTIFY_KEEP_AWAKE"), true),
    max_event_concurrency: parse_int.(System.get_env("MAX_EVENT_CONCURRENCY"), 8),
    webhook_max_skew_seconds: parse_int.(System.get_env("WEBHOOK_MAX_SKEW_SECONDS"), 300)
end
